-- =============================================================================
-- GoWait — Correção do cálculo de trend (tendência)
-- Migration: fix_trend_window
--
-- Problema identificado:
--   compute_trend() comparava snapshots históricos, mas calculate_crowd_score()
--   é DETERMINÍSTICA por bloco de hora — todos os snapshots dentro da mesma
--   hora têm score idêntico. Comparar "agora" vs "3h atrás" funciona apenas
--   nas transições de hora, e diz o que JÁ aconteceu — não o que vai acontecer.
--
-- Solução: tendency PREDITIVA
--   Comparar score(hora_atual) vs score(próxima_hora).
--   Responde: "vai ficar mais cheio ou mais vazio em breve?"
--   Não requer nenhum snapshot histórico. É sempre preciso.
--
-- Exemplos:
--   16:30 (score hora 16 = +8 pts) → próxima hora 17 = +25 pts → SUBINDO ✓
--   19:00 (score hora 19 = +25 pts) → próxima hora 20 = +12 pts → CAINDO ✓
--   18:00 (score hora 18 = +25 pts) → próxima hora 19 = +25 pts → ESTÁVEL ✓
--
-- Simplificações:
--   • Retenção de snapshots: 24 → 6 (volta ao original)
--     Não precisamos mais de histórico para trend. 6 snapshots = 1h30 de
--     contexto para o compute_trend() de transição (ainda mantido como fallback).
--
--   • crowd_score agora é escrito direto em locations (coluna nova).
--     O app elimina a segunda query em location_metrics.
--
-- Compatibilidade: não altera estrutura de tabelas existentes.
-- =============================================================================


-- ─── 1. Adicionar crowd_score + snapshot_at em locations (app usa 1 query só) ──

ALTER TABLE locations
  ADD COLUMN IF NOT EXISTS crowd_score  int         DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS snapshot_at  timestamptz DEFAULT NULL;


-- ─── 2. Reescrever compute_trend() como tendência preditiva ──────────────────
--
-- Recebe o location_id e calcula o score da PRÓXIMA hora vs hora atual,
-- usando os mesmos parâmetros do local (segment, price_level, size, etc.).
-- Não precisa de histórico. Sempre retorna uma resposta útil.

CREATE OR REPLACE FUNCTION compute_trend(p_location_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_loc         RECORD;
  v_now         timestamp := now() AT TIME ZONE 'America/Sao_Paulo';
  v_hour_now    int  := EXTRACT(hour FROM v_now)::int;
  v_hour_next   int  := (EXTRACT(hour FROM v_now)::int + 1) % 24;
  v_dow         int  := EXTRACT(dow  FROM v_now)::int;
  v_dom         int  := EXTRACT(day  FROM v_now)::int;
  v_is_weekend  bool := v_dow IN (0, 6);
  v_is_holiday  bool := false;  -- feriados: integração futura
  v_score_now   int;
  v_score_next  int;
  v_delta       int;
BEGIN
  SELECT segment, price_level, size, base_crowd_factor
  INTO v_loc
  FROM locations
  WHERE id = p_location_id;

  IF NOT FOUND THEN RETURN 'estável'; END IF;

  v_score_now  := calculate_crowd_score(
    v_loc.segment, v_loc.price_level, v_loc.size, v_loc.base_crowd_factor,
    v_hour_now,  v_is_weekend, v_is_holiday, v_dom
  );
  v_score_next := calculate_crowd_score(
    v_loc.segment, v_loc.price_level, v_loc.size, v_loc.base_crowd_factor,
    v_hour_next, v_is_weekend, v_is_holiday, v_dom
  );

  v_delta := v_score_next - v_score_now;

  RETURN CASE
    WHEN v_delta >  5 THEN 'subindo'
    WHEN v_delta < -5 THEN 'caindo'
    ELSE 'estável'
  END;
END;
$$;


-- ─── 3. Reescrever run_location_snapshot() com:  ──────────────────────────────
--   • Retenção 6 snapshots (era 24 — não precisamos mais do histórico longo)
--   • Escreve crowd_score em locations (elimina query extra no app)
--   • trend calculado pela nova compute_trend() preditiva

CREATE OR REPLACE FUNCTION run_location_snapshot()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_location    RECORD;
  v_now         timestamp := now() AT TIME ZONE 'America/Sao_Paulo';
  v_hour        int  := EXTRACT(hour  FROM v_now)::int;
  v_dow         int  := EXTRACT(dow   FROM v_now)::int;
  v_dom         int  := EXTRACT(day   FROM v_now)::int;
  v_is_weekend  bool := v_dow IN (0, 6);
  v_is_holiday  bool := false;
  v_score       int;
  v_flow        text;
  v_wait        text;
  v_trend       text;
  v_open        bool;
BEGIN
  FOR v_location IN
    SELECT id, segment, price_level, size, base_crowd_factor, slug, vertical
    FROM locations
  LOOP
    v_open := is_location_open(v_location.id);
    UPDATE locations SET is_open = v_open WHERE id = v_location.id;
    CONTINUE WHEN NOT v_open;

    v_score := calculate_crowd_score(
      v_location.segment, v_location.price_level, v_location.size,
      v_location.base_crowd_factor, v_hour, v_is_weekend, v_is_holiday, v_dom
    );

    v_flow  := crowd_score_to_flow(v_score);
    v_wait  := crowd_score_to_wait_time(v_score);
    v_trend := compute_trend(v_location.id);  -- agora é preditivo, não histórico

    INSERT INTO location_metrics (
      location_id, slug, vertical, crowd_score, flow, wait_time, trend,
      is_holiday, is_weekend, day_of_week, hour_of_day, weather
    ) VALUES (
      v_location.id, v_location.slug, v_location.vertical,
      v_score, v_flow, v_wait, v_trend,
      v_is_holiday, v_is_weekend, v_dow, v_hour, NULL
    );

    -- Escreve tudo em locations → app faz apenas 1 query, sem JOIN
    UPDATE locations
    SET flow        = v_flow,
        wait_time   = v_wait,
        trend       = v_trend,
        crowd_score = v_score,
        snapshot_at = now()
    WHERE id = v_location.id;

  END LOOP;

  -- Retenção: 6 snapshots por local (1h30 de histórico — suficiente para auditoria)
  DELETE FROM location_metrics
  WHERE id NOT IN (
    SELECT id FROM (
      SELECT id,
             ROW_NUMBER() OVER (PARTITION BY location_id ORDER BY created_at DESC) AS rn
      FROM location_metrics
    ) ranked
    WHERE rn <= 6
  );
END;
$$;


-- ─── 4. TTL de 90 dias em location_user_signals ──────────────────────────────
--
-- Evita crescimento ilimitado da tabela.
-- Free plan Supabase: 500MB. Cada linha ≈ 400 bytes → ~1.25M linhas máximo.
-- 90 dias garante dados suficientes para o modelo sem risco de estouro.
--
-- Agendar via pg_cron após rodar esta migration:
--   SELECT cron.schedule(
--     'cleanup-signals',
--     '0 3 * * *',
--     'DELETE FROM location_user_signals WHERE created_at < now() - interval ''90 days'''
--   );

-- Limpeza manual inicial (remove dados anteriores a 90 dias, se houver):
DELETE FROM location_user_signals
WHERE created_at < now() - interval '90 days';


-- ─── Notas finais ──────────────────────────────────────────────────────────────
--
-- Após rodar esta migration:
--
-- 1. Verificar trend preditivo:
--    SELECT id, name, flow, trend, crowd_score FROM locations;
--    → trend deve mudar conforme o horário do dia.
--
-- 2. Agendar limpeza de sinais:
--    SELECT cron.schedule('cleanup-signals','0 3 * * *',
--      'DELETE FROM location_user_signals WHERE created_at < now() - interval ''90 days''');
--
-- 3. A camada IA (location_signal_aggregate, location_model_weights,
--    location_intelligence) continua dormindo — ativar só quando houver
--    >= 200 sinais e >= 20 feedbacks por local.

--
-- Problema identificado:
--   A função compute_trend() quase sempre retorna 'estável' por dois motivos:
--
--   1. Janela muito curta: o sistema retinha apenas 6 snapshots (≈1h30).
--      Todos os 6 ficavam dentro do mesmo intervalo de hora do dia.
--      Como calculate_crowd_score() é DETERMINÍSTICA por hora, todos os 6
--      scores eram iguais → delta ≈ 0 → sempre 'estável'.
--
--   2. Threshold muito alto: ±8 pontos é grande para comparar metades de 1h30.
--      A variação real entre horas consecutivas pode ser 5–17 pontos.
--
-- Solução:
--   a) Aumentar retenção de 6 → 24 snapshots por local (≈6h de histórico)
--   b) Reescrever compute_trend() para comparar snapshots RECENTES (última 1h)
--      vs snapshots de 2–3h atrás — cruzando fronteiras de hora reais
--   c) Reduzir threshold de ±8 → ±5 (mais sensível)
--
-- Exemplo de variação real por hora (pico noturno em dia útil):
--   14h–16h: +8 pts  →  17h–19h: +25 pts  →  20h–21h: +12 pts
--   Transição 16h→17h: delta ≈ +17  → deve mostrar 'subindo'
--   Transição 19h→20h: delta ≈ -13  → deve mostrar 'caindo'
--
-- Compatibilidade: não altera tabelas. Sobrescreve funções existentes.
-- =============================================================================


-- ─── 1. Aumentar retenção de snapshots: 6 → 24 por local ─────────────────────
--
-- 24 snapshots × 15min = 6h de histórico
-- Suficiente para detectar variação entre manhã, tarde e pico noturno
-- Impacto de storage: ~24 rows por local (mínimo — tabela já existente)

CREATE OR REPLACE FUNCTION run_location_snapshot()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_location    RECORD;
  v_now         timestamp := now() AT TIME ZONE 'America/Sao_Paulo';
  v_hour        int  := EXTRACT(hour  FROM v_now)::int;
  v_dow         int  := EXTRACT(dow   FROM v_now)::int;
  v_dom         int  := EXTRACT(day   FROM v_now)::int;
  v_is_weekend  bool := v_dow IN (0, 6);
  v_is_holiday  bool := false;
  v_score       int;
  v_flow        text;
  v_wait        text;
  v_trend       text;
  v_open        bool;
BEGIN
  FOR v_location IN
    SELECT id, segment, price_level, size, base_crowd_factor, slug, vertical
    FROM locations
  LOOP
    v_open := is_location_open(v_location.id);

    -- Atualiza is_open independentemente (app mostra status correto)
    UPDATE locations SET is_open = v_open WHERE id = v_location.id;

    -- Pula snapshot se fechado
    CONTINUE WHEN NOT v_open;

    v_score := calculate_crowd_score(
      v_location.segment,
      v_location.price_level,
      v_location.size,
      v_location.base_crowd_factor,
      v_hour,
      v_is_weekend,
      v_is_holiday,
      v_dom
    );

    v_flow  := crowd_score_to_flow(v_score);
    v_wait  := crowd_score_to_wait_time(v_score);
    v_trend := compute_trend(v_location.id);

    INSERT INTO location_metrics (
      location_id, slug, vertical, crowd_score, flow, wait_time, trend,
      is_holiday, is_weekend, day_of_week, hour_of_day, weather
    ) VALUES (
      v_location.id, v_location.slug, v_location.vertical,
      v_score, v_flow, v_wait, v_trend,
      v_is_holiday, v_is_weekend, v_dow, v_hour, NULL
    );

    UPDATE locations
    SET flow      = v_flow,
        wait_time = v_wait,
        trend     = v_trend
    WHERE id = v_location.id;

  END LOOP;

  -- ── MUDANÇA PRINCIPAL: reter 24 snapshots (era 6) ──────────────────────────
  -- 24 × 15min = 6h de histórico → cobre variação manhã / tarde / pico
  DELETE FROM location_metrics
  WHERE id NOT IN (
    SELECT id FROM (
      SELECT id,
             ROW_NUMBER() OVER (PARTITION BY location_id ORDER BY created_at DESC) AS rn
      FROM location_metrics
    ) ranked
    WHERE rn <= 24
  );
END;
$$;


-- ─── 2. Reescrever compute_trend() ───────────────────────────────────────────
--
-- Nova lógica:
--   - Busca os últimos 24 snapshots (até 6h)
--   - "Recente"  = últimos 4 snapshots (≈1h, pode estar dentro de 1 hora do dia)
--   - "Passado"  = snapshots de posição 9–12 (≈2h–3h atrás)
--     → essa distância garante cruzar pelo menos 1–2 fronteiras de hora
--   - Threshold: ±5 pts (era ±8 — mais sensível a transições reais)
--
-- Por que posições 9–12 para o "passado"?
--   Posições 1–4   = agora (≈0–1h)
--   Posições 5–8   = ≈1h–2h atrás (pode ser a mesma hora, skip)
--   Posições 9–12  = ≈2h–3h atrás (quase sempre hora diferente → delta real)
--
-- Fallback: se não há snapshots suficientes → 'estável' (comportamento seguro)

CREATE OR REPLACE FUNCTION compute_trend(p_location_id uuid)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_scores    int[];
  v_n         int;
  v_recent    numeric;
  v_past      numeric;
  v_delta     numeric;
BEGIN
  -- Busca até 24 snapshots ordenados do mais recente ao mais antigo
  SELECT ARRAY_AGG(crowd_score ORDER BY created_at DESC)
  INTO v_scores
  FROM (
    SELECT crowd_score, created_at
    FROM location_metrics
    WHERE location_id = p_location_id
    ORDER BY created_at DESC
    LIMIT 24
  ) sub;

  v_n := COALESCE(ARRAY_LENGTH(v_scores, 1), 0);

  -- Precisa de pelo menos 12 snapshots (3h) para comparação cruzando horas
  IF v_n < 12 THEN
    RETURN 'estável';
  END IF;

  -- Média recente: posições 1–4 (últimos ≈60min)
  v_recent := (SELECT AVG(v) FROM UNNEST(v_scores[1:4])   AS v);

  -- Média passada: posições 9–12 (≈2h–3h atrás)
  v_past   := (SELECT AVG(v) FROM UNNEST(v_scores[9:12])  AS v);

  -- Delta: positivo = subindo, negativo = caindo
  v_delta := v_recent - v_past;

  RETURN CASE
    WHEN v_delta >  5 THEN 'subindo'
    WHEN v_delta < -5 THEN 'caindo'
    ELSE 'estável'
  END;
END;
$$;


-- ─── Notas para validação ─────────────────────────────────────────────────────
--
-- Após rodar esta migration, aguardar ≈3h para acumular 12+ snapshots.
-- Então validar com:
--
--   SELECT
--     l.name,
--     l.trend,
--     l.flow,
--     COUNT(lm.id)           AS snapshots_retidos,
--     MIN(lm.crowd_score)    AS score_min,
--     MAX(lm.crowd_score)    AS score_max,
--     ROUND(AVG(lm.crowd_score), 1) AS score_avg
--   FROM locations l
--   JOIN location_metrics lm ON lm.location_id = l.id
--   GROUP BY l.id, l.name, l.trend, l.flow
--   ORDER BY (MAX(lm.crowd_score) - MIN(lm.crowd_score)) DESC;
--
-- Espera-se ver trend = 'subindo' nos locais com score crescendo ao longo
-- das últimas 3h e 'caindo' onde o score caiu (ex: após pico das 17h–19h).
