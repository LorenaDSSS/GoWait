-- =============================================================================
-- GoWait — Camada de Inteligência Unificada
-- Migration: location_intelligence
--
-- Objetivo:
--   Fundir três fontes de dados em um único score de decisão confiável:
--
--   1. Heurística (crowd_score de location_metrics)
--      → "o que o modelo prevê com base em hora, dia, tipo de local"
--
--   2. Comportamento do usuário (location_user_signals)
--      → "o que as ações dos usuários revelam sobre a percepção real"
--
--   3. Feedback direto (lus.feedback_value)
--      → "o que o usuário declarou explicitamente ao visitar o local"
--
-- Formula central:
--   intelligence_score =
--     weight_heuristic  × crowd_score
--   + weight_behavioral × behavioral_score
--   + weight_feedback   × feedback_score
--   + baseline_adjustment
--
-- Frequência de atualização (sem aumentar custo do sistema):
--   • Real-time  : location_user_signals  (INSERT já ocorre no app)
--   • 15 min     : run_location_snapshot() (já agendado via pg_cron)
--   • 2h (batch) : aggregate_location_signals() + refresh_location_intelligence()
--   • Diário     : calibrate_model_weights()
--
-- Compatibilidade:
--   Não altera nenhuma tabela/coluna existente.
--   Apenas ADICIONA: novas tabelas, novas funções, nova coluna intelligence_score.
-- =============================================================================


-- =============================================================================
-- TABELA 1: location_signal_aggregate
-- Pré-agregação de sinais comportamentais por location + janela de 3h
-- Atualizada a cada 2h por pg_cron (não em tempo real — economia de compute)
-- =============================================================================

CREATE TABLE IF NOT EXISTS location_signal_aggregate (
  id                      uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  location_id             uuid        NOT NULL REFERENCES locations(id) ON DELETE CASCADE,

  -- Janela temporal desta agregação
  -- Sempre o início da janela de 3h em horário Brasil (ex: 06:00, 09:00...)
  window_start            timestamptz NOT NULL,

  -- Volume de sinais nesta janela
  total_signals           int         NOT NULL DEFAULT 0,

  -- Métricas de intenção
  avg_intent_score        numeric(5,2),

  -- Taxas de comportamento (0.0 a 1.0)
  dismiss_rate            numeric(5,4),   -- dismissals / total_signals
  navigate_rate           numeric(5,4),   -- navigations / total_signals
  return_rate             numeric(5,4),   -- returns / total_signals

  -- Dwell time médio nos dashboards abertos (segundos)
  avg_dwell_seconds       numeric(6,1),

  -- Score comportamental derivado (0-100)
  -- interpretação: "o que o comportamento sugere sobre a lotação real"
  behavioral_score        int,

  -- Feedback declarado nesta janela
  feedback_count          int         NOT NULL DEFAULT 0,
  count_vazio             int         NOT NULL DEFAULT 0,
  count_normal            int         NOT NULL DEFAULT 0,
  count_cheio             int         NOT NULL DEFAULT 0,

  -- Score percebido: vazio=15, normal=50, cheio=85
  avg_perceived_score     numeric(5,2),

  -- Crowd score heurístico médio no momento dos eventos (referência)
  avg_heuristic_at_event  numeric(5,2),

  -- Divergência entre percepção e heurística (+ = local mais cheio do que previsto)
  perception_delta        numeric(6,2),

  updated_at              timestamptz NOT NULL DEFAULT now(),

  UNIQUE (location_id, window_start)
);

CREATE INDEX IF NOT EXISTS idx_lsa_location_window
  ON location_signal_aggregate (location_id, window_start DESC);

CREATE INDEX IF NOT EXISTS idx_lsa_window
  ON location_signal_aggregate (window_start DESC);


-- =============================================================================
-- TABELA 2: location_model_weights
-- Pesos do modelo por location — ajustados diariamente via calibrate_model_weights()
--
-- Inicialmente o modelo confia mais na heurística.
-- Conforme dados de comportamento e feedback acumulam, os pesos se deslocam.
-- =============================================================================

CREATE TABLE IF NOT EXISTS location_model_weights (
  location_id           uuid        PRIMARY KEY REFERENCES locations(id) ON DELETE CASCADE,

  -- Pesos somam 1.0
  weight_heuristic      numeric(5,4) NOT NULL DEFAULT 0.80,
  weight_behavioral     numeric(5,4) NOT NULL DEFAULT 0.15,
  weight_feedback       numeric(5,4) NOT NULL DEFAULT 0.05,

  -- Ajuste aditivo descoberto pela calibração (-20 a +20)
  -- Exemplo: se o sistema sistematicamente subestima em 8 pontos → +8
  baseline_adjustment   numeric(5,2) NOT NULL DEFAULT 0.00,

  -- Contadores de volume acumulado (usados para decidir quando aumentar pesos)
  total_signals_ever    int          NOT NULL DEFAULT 0,
  total_feedback_ever   int          NOT NULL DEFAULT 0,

  -- Qualidade do modelo: MAE médio da última semana (menor = melhor)
  -- null enquanto não há dados suficientes para calcular
  mean_absolute_error   numeric(5,2),

  last_calibrated_at    timestamptz  NOT NULL DEFAULT now(),
  created_at            timestamptz  NOT NULL DEFAULT now()
);


-- =============================================================================
-- TABELA 3: location_intelligence
-- Score unificado final por location — calculado pelo modelo híbrido
-- Consultada pelo app e pelo painel admin
-- =============================================================================

CREATE TABLE IF NOT EXISTS location_intelligence (
  location_id             uuid        PRIMARY KEY REFERENCES locations(id) ON DELETE CASCADE,

  -- Score principal: fusão ponderada dos três sinais
  intelligence_score      int         NOT NULL DEFAULT 0
                          CHECK (intelligence_score BETWEEN 0 AND 100),

  -- Detalhamento para debug / auditoria
  heuristic_score         int,        -- crowd_score mais recente
  behavioral_score        int,        -- sinal comportamental
  feedback_score          int,        -- percepção declarada
  baseline_adj_applied    numeric(5,2),

  -- Pesos utilizados neste cálculo
  w_heuristic             numeric(5,4),
  w_behavioral            numeric(5,4),
  w_feedback              numeric(5,4),

  -- Confiabilidade do score
  -- low    : < 10 sinais totais ou nenhum feedback
  -- medium : 10–49 sinais ou 1–9 feedbacks
  -- high   : >= 50 sinais e >= 10 feedbacks
  confidence_level        text        NOT NULL DEFAULT 'low'
                          CHECK (confidence_level IN ('low', 'medium', 'high')),

  -- Delta de percepção: positivo = local mais cheio do que o modelo prevê
  perception_delta        numeric(6,2),

  last_computed_at        timestamptz NOT NULL DEFAULT now()
);

-- Coluna adicionada à tabela locations para consumo direto pelo app
-- (evita JOIN obrigatório a cada query de lista)
ALTER TABLE locations
  ADD COLUMN IF NOT EXISTS intelligence_score int DEFAULT NULL;


-- =============================================================================
-- FUNÇÃO 1: aggregate_location_signals()
-- Roda a cada 2h via pg_cron.
-- Lê location_user_signals do últimas 7 dias e upserta em location_signal_aggregate.
-- Usa janelas de 3h alinhadas ao horário Brasil.
-- =============================================================================

CREATE OR REPLACE FUNCTION aggregate_location_signals()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_cutoff timestamptz := now() - interval '7 days';
BEGIN
  -- UPSERT: recalcula janelas existentes das últimas 7 dias
  -- Janela de 3h: floor(hour / 3) * 3 → 0, 3, 6, 9, 12, 15, 18, 21
  INSERT INTO location_signal_aggregate (
    location_id,
    window_start,
    total_signals,
    avg_intent_score,
    dismiss_rate,
    navigate_rate,
    return_rate,
    avg_dwell_seconds,
    behavioral_score,
    feedback_count,
    count_vazio,
    count_normal,
    count_cheio,
    avg_perceived_score,
    avg_heuristic_at_event,
    perception_delta,
    updated_at
  )
  SELECT
    location_id,

    -- Início da janela de 3h no fuso Brasil
    date_trunc('hour', created_at AT TIME ZONE 'America/Sao_Paulo')
      - (EXTRACT(hour FROM created_at AT TIME ZONE 'America/Sao_Paulo')::int % 3)
      * interval '1 hour'                                            AS window_start,

    COUNT(*)                                                          AS total_signals,
    ROUND(AVG(intent_score), 2)                                       AS avg_intent_score,

    -- Taxas de comportamento
    ROUND(
      COUNT(*) FILTER (WHERE event_type = 'dismiss')::numeric
      / NULLIF(COUNT(*), 0), 4
    )                                                                 AS dismiss_rate,
    ROUND(
      COUNT(*) FILTER (WHERE event_type = 'navigate')::numeric
      / NULLIF(COUNT(*), 0), 4
    )                                                                 AS navigate_rate,
    ROUND(
      COUNT(*) FILTER (WHERE event_type = 'return')::numeric
      / NULLIF(COUNT(*), 0), 4
    )                                                                 AS return_rate,

    ROUND(AVG(dwell_time_seconds) FILTER (WHERE dwell_time_seconds IS NOT NULL), 1) AS avg_dwell_seconds,

    -- behavioral_score:
    -- Base no avg_intent_score. Ajuste por dismiss (sugere local mais cheio do que parece)
    -- e navigate (usuários estão indo = fluxo aceitável).
    --   dismiss elevado (+) → score sobe (local pode estar mais cheio)
    --   navigate elevado (-)→ score desce (usuários confiam, fluxo parece ok)
    LEAST(100, GREATEST(0, ROUND(
      COALESCE(AVG(intent_score), 50)
      + (
          COALESCE(
            COUNT(*) FILTER (WHERE event_type = 'dismiss')::numeric
            / NULLIF(COUNT(*), 0), 0
          ) - 0.30
        ) * 80
      - (
          COALESCE(
            COUNT(*) FILTER (WHERE event_type = 'navigate')::numeric
            / NULLIF(COUNT(*), 0), 0
          ) - 0.15
        ) * 60
    )))::int                                                          AS behavioral_score,

    -- Feedback declarado
    COUNT(*) FILTER (WHERE event_type = 'feedback')                  AS feedback_count,
    COUNT(*) FILTER (WHERE feedback_value = 'vazio')                 AS count_vazio,
    COUNT(*) FILTER (WHERE feedback_value = 'normal')                AS count_normal,
    COUNT(*) FILTER (WHERE feedback_value = 'cheio')                 AS count_cheio,

    -- Score percebido: vazio=15, normal=50, cheio=85
    ROUND(AVG(
      CASE feedback_value
        WHEN 'vazio'  THEN 15
        WHEN 'normal' THEN 50
        WHEN 'cheio'  THEN 85
        ELSE NULL
      END
    ), 2)                                                             AS avg_perceived_score,

    ROUND(AVG(score_at_event), 2)                                     AS avg_heuristic_at_event,

    -- Delta de percepção (positivo = mais cheio do que o modelo previa)
    ROUND(
      AVG(
        CASE feedback_value
          WHEN 'vazio'  THEN 15
          WHEN 'normal' THEN 50
          WHEN 'cheio'  THEN 85
          ELSE NULL
        END
      ) - AVG(score_at_event), 2
    )                                                                 AS perception_delta,

    now()                                                             AS updated_at

  FROM location_user_signals
  WHERE created_at >= v_cutoff
  GROUP BY
    location_id,
    date_trunc('hour', created_at AT TIME ZONE 'America/Sao_Paulo')
      - (EXTRACT(hour FROM created_at AT TIME ZONE 'America/Sao_Paulo')::int % 3)
      * interval '1 hour'

  ON CONFLICT (location_id, window_start)
  DO UPDATE SET
    total_signals           = EXCLUDED.total_signals,
    avg_intent_score        = EXCLUDED.avg_intent_score,
    dismiss_rate            = EXCLUDED.dismiss_rate,
    navigate_rate           = EXCLUDED.navigate_rate,
    return_rate             = EXCLUDED.return_rate,
    avg_dwell_seconds       = EXCLUDED.avg_dwell_seconds,
    behavioral_score        = EXCLUDED.behavioral_score,
    feedback_count          = EXCLUDED.feedback_count,
    count_vazio             = EXCLUDED.count_vazio,
    count_normal            = EXCLUDED.count_normal,
    count_cheio             = EXCLUDED.count_cheio,
    avg_perceived_score     = EXCLUDED.avg_perceived_score,
    avg_heuristic_at_event  = EXCLUDED.avg_heuristic_at_event,
    perception_delta        = EXCLUDED.perception_delta,
    updated_at              = now();
END;
$$;


-- =============================================================================
-- FUNÇÃO 2: calibrate_model_weights()
-- Roda 1x por dia (3h da manhã, horário Brasil).
--
-- O que faz:
--   a) Garante que todo location tenha um registro em location_model_weights
--   b) Atualiza total_signals_ever e total_feedback_ever
--   c) Ajusta pesos dinamicamente conforme volume de dados acumula
--   d) Calcula baseline_adjustment corrigindo erro sistemático detectado
--   e) Calcula mean_absolute_error dos últimos 7 dias
--
-- Regra de escada dos pesos (automática, incremental):
--   Fase 1 (< 50 sinais, < 5 feedbacks):
--     heuristic=0.80, behavioral=0.15, feedback=0.05
--   Fase 2 (50–199 sinais OU 5–19 feedbacks):
--     heuristic=0.65, behavioral=0.25, feedback=0.10
--   Fase 3 (>= 200 sinais E >= 20 feedbacks):
--     heuristic=0.50, behavioral=0.30, feedback=0.20
-- =============================================================================

CREATE OR REPLACE FUNCTION calibrate_model_weights()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_loc RECORD;
BEGIN
  FOR v_loc IN SELECT id FROM locations LOOP

    -- Totais acumulados
    WITH totals AS (
      SELECT
        COUNT(*)                                   AS total_signals,
        COUNT(*) FILTER (WHERE event_type = 'feedback') AS total_feedback
      FROM location_user_signals
      WHERE location_id = v_loc.id
    ),
    -- Erro sistemático: média de (perceived - heuristic) nos últimos 30 dias
    divergence AS (
      SELECT ROUND(AVG(perception_delta), 2) AS avg_delta
      FROM location_signal_aggregate
      WHERE location_id = v_loc.id
        AND feedback_count > 0
        AND window_start >= now() - interval '30 days'
    ),
    -- MAE dos últimos 7 dias: | perceived - heuristic |
    mae AS (
      SELECT ROUND(AVG(ABS(perception_delta)), 2) AS mae_value
      FROM location_signal_aggregate
      WHERE location_id = v_loc.id
        AND feedback_count > 0
        AND window_start >= now() - interval '7 days'
    )
    INSERT INTO location_model_weights (
      location_id,
      weight_heuristic,
      weight_behavioral,
      weight_feedback,
      baseline_adjustment,
      total_signals_ever,
      total_feedback_ever,
      mean_absolute_error,
      last_calibrated_at
    )
    SELECT
      v_loc.id,

      -- Fase dos pesos (escada)
      CASE
        WHEN t.total_signals >= 200 AND t.total_feedback >= 20 THEN 0.50
        WHEN t.total_signals >= 50  OR  t.total_feedback >= 5  THEN 0.65
        ELSE 0.80
      END AS weight_heuristic,

      CASE
        WHEN t.total_signals >= 200 AND t.total_feedback >= 20 THEN 0.30
        WHEN t.total_signals >= 50  OR  t.total_feedback >= 5  THEN 0.25
        ELSE 0.15
      END AS weight_behavioral,

      CASE
        WHEN t.total_signals >= 200 AND t.total_feedback >= 20 THEN 0.20
        WHEN t.total_signals >= 50  OR  t.total_feedback >= 5  THEN 0.10
        ELSE 0.05
      END AS weight_feedback,

      -- baseline_adjustment: corrige erro sistemático observado
      -- Limita em ±15 para evitar overfitting
      GREATEST(-15, LEAST(15, COALESCE(d.avg_delta * 0.5, 0.0)))::numeric(5,2),

      t.total_signals::int,
      t.total_feedback::int,
      m.mae_value,
      now()

    FROM totals t
    CROSS JOIN divergence d
    CROSS JOIN mae m

    ON CONFLICT (location_id)
    DO UPDATE SET
      weight_heuristic    = EXCLUDED.weight_heuristic,
      weight_behavioral   = EXCLUDED.weight_behavioral,
      weight_feedback     = EXCLUDED.weight_feedback,
      baseline_adjustment = EXCLUDED.baseline_adjustment,
      total_signals_ever  = EXCLUDED.total_signals_ever,
      total_feedback_ever = EXCLUDED.total_feedback_ever,
      mean_absolute_error = EXCLUDED.mean_absolute_error,
      last_calibrated_at  = now();

  END LOOP;
END;
$$;


-- =============================================================================
-- FUNÇÃO 3: calculate_intelligence_score(location_id)
-- Função pura: recebe um location_id e devolve o score unificado.
-- Lê: location_metrics (1 row), location_signal_aggregate (janela atual),
--      location_model_weights (pesos).
-- =============================================================================

CREATE OR REPLACE FUNCTION calculate_intelligence_score(p_location_id uuid)
RETURNS TABLE (
  intelligence_score   int,
  heuristic_score      int,
  behavioral_score     int,
  feedback_score       int,
  baseline_adj_applied numeric,
  w_heuristic          numeric,
  w_behavioral         numeric,
  w_feedback           numeric,
  confidence_level     text,
  perception_delta     numeric
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_heuristic     int;
  v_behavioral    int;
  v_feedback      int;
  v_w_h           numeric := 0.80;
  v_w_b           numeric := 0.15;
  v_w_f           numeric := 0.05;
  v_baseline      numeric := 0.00;
  v_total_signals int     := 0;
  v_fb_count      int     := 0;
  v_delta         numeric;
  v_score         int;
  v_confidence    text;
BEGIN
  -- 1. Score heurístico: crowd_score mais recente de location_metrics
  SELECT COALESCE(lm.crowd_score, 40)
  INTO v_heuristic
  FROM location_metrics lm
  WHERE lm.location_id = p_location_id
  ORDER BY lm.created_at DESC
  LIMIT 1;

  v_heuristic := COALESCE(v_heuristic, 40);

  -- 2. Pesos calibrados (usa defaults se não calibrado ainda)
  SELECT
    lmw.weight_heuristic,
    lmw.weight_behavioral,
    lmw.weight_feedback,
    lmw.baseline_adjustment
  INTO v_w_h, v_w_b, v_w_f, v_baseline
  FROM location_model_weights lmw
  WHERE lmw.location_id = p_location_id;

  v_w_h      := COALESCE(v_w_h,      0.80);
  v_w_b      := COALESCE(v_w_b,      0.15);
  v_w_f      := COALESCE(v_w_f,      0.05);
  v_baseline := COALESCE(v_baseline,  0.00);

  -- 3. Sinais comportamentais da janela atual (3h mais recente com dados)
  SELECT
    COALESCE(lsa.behavioral_score, v_heuristic),
    COALESCE(lsa.feedback_count,   0),
    COALESCE(lsa.avg_perceived_score::int, v_heuristic),
    COALESCE(lsa.total_signals,    0),
    lsa.perception_delta
  INTO v_behavioral, v_fb_count, v_feedback, v_total_signals, v_delta
  FROM location_signal_aggregate lsa
  WHERE lsa.location_id = p_location_id
  ORDER BY lsa.window_start DESC
  LIMIT 1;

  -- Fallback: sem dados comportamentais → usa heurística
  v_behavioral    := COALESCE(v_behavioral,    v_heuristic);
  v_feedback      := COALESCE(v_feedback,      v_heuristic);
  v_total_signals := COALESCE(v_total_signals, 0);
  v_fb_count      := COALESCE(v_fb_count,      0);

  -- Se feedback_count < 5, o feedback_score não é confiável → usa heurística mesmo
  IF v_fb_count < 5 THEN
    v_feedback := v_heuristic;
  END IF;

  -- 4. Cálculo do score unificado
  v_score := LEAST(100, GREATEST(0, ROUND(
    v_w_h * v_heuristic
    + v_w_b * v_behavioral
    + v_w_f * v_feedback
    + v_baseline
  )::int));

  -- 5. Nível de confiança
  v_confidence := CASE
    WHEN v_total_signals >= 50 AND v_fb_count >= 10 THEN 'high'
    WHEN v_total_signals >= 10 OR  v_fb_count >= 3  THEN 'medium'
    ELSE 'low'
  END;

  RETURN QUERY SELECT
    v_score,
    v_heuristic,
    v_behavioral,
    v_feedback,
    v_baseline,
    v_w_h,
    v_w_b,
    v_w_f,
    v_confidence,
    v_delta;
END;
$$;


-- =============================================================================
-- FUNÇÃO 4: refresh_location_intelligence()
-- Roda a cada 2h via pg_cron (logo após aggregate_location_signals).
-- Calcula o intelligence_score para todos os locations e persiste.
-- Também atualiza a coluna intelligence_score em locations (consumo direto pelo app).
-- =============================================================================

CREATE OR REPLACE FUNCTION refresh_location_intelligence()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_loc   RECORD;
  v_calc  RECORD;
BEGIN
  FOR v_loc IN SELECT id FROM locations LOOP

    SELECT * INTO v_calc
    FROM calculate_intelligence_score(v_loc.id);

    INSERT INTO location_intelligence (
      location_id,
      intelligence_score,
      heuristic_score,
      behavioral_score,
      feedback_score,
      baseline_adj_applied,
      w_heuristic,
      w_behavioral,
      w_feedback,
      confidence_level,
      perception_delta,
      last_computed_at
    )
    VALUES (
      v_loc.id,
      v_calc.intelligence_score,
      v_calc.heuristic_score,
      v_calc.behavioral_score,
      v_calc.feedback_score,
      v_calc.baseline_adj_applied,
      v_calc.w_heuristic,
      v_calc.w_behavioral,
      v_calc.w_feedback,
      v_calc.confidence_level,
      v_calc.perception_delta,
      now()
    )
    ON CONFLICT (location_id) DO UPDATE SET
      intelligence_score   = EXCLUDED.intelligence_score,
      heuristic_score      = EXCLUDED.heuristic_score,
      behavioral_score     = EXCLUDED.behavioral_score,
      feedback_score       = EXCLUDED.feedback_score,
      baseline_adj_applied = EXCLUDED.baseline_adj_applied,
      w_heuristic          = EXCLUDED.w_heuristic,
      w_behavioral         = EXCLUDED.w_behavioral,
      w_feedback           = EXCLUDED.w_feedback,
      confidence_level     = EXCLUDED.confidence_level,
      perception_delta     = EXCLUDED.perception_delta,
      last_computed_at     = now();

    -- Propaga para locations (consumo direto sem JOIN)
    UPDATE locations
    SET intelligence_score = v_calc.intelligence_score
    WHERE id = v_loc.id;

  END LOOP;
END;
$$;


-- =============================================================================
-- VIEW: location_intelligence_debug
-- Para o painel admin: mostra o score de cada location com todos os componentes
-- e indica onde o modelo está errando mais.
-- =============================================================================

CREATE OR REPLACE VIEW location_intelligence_debug AS
SELECT
  l.id                                          AS location_id,
  l.name,
  l.vertical,
  l.flow,
  l.intelligence_score,
  li.heuristic_score,
  li.behavioral_score,
  li.feedback_score,
  li.confidence_level,
  li.perception_delta,
  li.w_heuristic,
  li.w_behavioral,
  li.w_feedback,
  li.baseline_adj_applied,
  li.last_computed_at,

  -- Alerta: divergência alta entre percepção e heurística
  CASE WHEN ABS(COALESCE(li.perception_delta, 0)) > 15
       THEN true ELSE false END                 AS has_divergence_alert,

  -- Quantos sinais e feedbacks acumulados
  mw.total_signals_ever,
  mw.total_feedback_ever,
  mw.mean_absolute_error,
  mw.last_calibrated_at

FROM locations l
LEFT JOIN location_intelligence li  ON li.location_id = l.id
LEFT JOIN location_model_weights mw ON mw.location_id = l.id
ORDER BY ABS(COALESCE(li.perception_delta, 0)) DESC;


-- =============================================================================
-- AGENDAMENTOS pg_cron
-- Execute manualmente no SQL Editor após habilitar a extensão pg_cron.
--
-- ▸ Já existente (NÃO ALTERAR):
--   SELECT cron.schedule('location-snapshot', '*/15 * * * *',
--     'SELECT run_location_snapshot()');
--
-- ▸ NOVOS — executar uma vez:
--
--   -- Agrega sinais a cada 2h
--   SELECT cron.schedule(
--     'aggregate-signals',
--     '0 */2 * * *',
--     'SELECT aggregate_location_signals()'
--   );
--
--   -- Recalcula intelligence_score logo após a agregação (2 min depois)
--   SELECT cron.schedule(
--     'refresh-intelligence',
--     '2 */2 * * *',
--     'SELECT refresh_location_intelligence()'
--   );
--
--   -- Recalibra pesos do modelo todo dia às 3h (horário Brasil = 6h UTC)
--   SELECT cron.schedule(
--     'calibrate-weights',
--     '0 6 * * *',
--     'SELECT calibrate_model_weights()'
--   );
--
-- Para verificar todos os jobs:
--   SELECT jobname, schedule, command, active FROM cron.job ORDER BY jobname;
-- =============================================================================
