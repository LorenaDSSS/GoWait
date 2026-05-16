-- =============================================================================
-- GoWait — Camada de Sinais de Comportamento do Usuário
-- Migration: location_user_signals
--
-- Objetivo:
--   Registrar interações reais dos usuários com locais para alimentar
--   a camada de inteligência comportamental do GoWait.
--
--   Essa tabela complementa location_metrics (heurística) com sinais
--   de intenção humana, permitindo no futuro um modelo híbrido:
--   crowd_score_ajustado = f(heurística, comportamento_real)
--
-- Eventos capturados:
--   search   → usuário buscou pelo local (intent baixo)
--   view     → usuário abriu o dashboard do local
--   click    → usuário selecionou um local da lista
--   navigate → usuário iniciou rota ao local (intent máximo)
--   dismiss  → usuário fechou o local antes de navegar
--   return   → usuário voltou ao mesmo local após dismiss
--
-- Não aumenta frequência de snapshots. É camada complementar.
-- =============================================================================

CREATE TABLE IF NOT EXISTS location_user_signals (
  id                  uuid        DEFAULT gen_random_uuid() PRIMARY KEY,

  -- Referência ao local
  location_id         uuid        NOT NULL REFERENCES locations(id) ON DELETE CASCADE,

  -- Tipo de interação
  event_type          text        NOT NULL
                      CHECK (event_type IN ('view', 'search', 'click', 'navigate', 'dismiss', 'return')),

  -- Score de intenção derivado do event_type (calculado no cliente)
  -- search=20, view=30, dismiss=10, click=60, return=75, navigate=90
  intent_score        int         NOT NULL CHECK (intent_score BETWEEN 0 AND 100),

  -- Tempo que o usuário ficou visualizando o dashboard (só para event_type='view')
  dwell_time_seconds  int,

  -- Origem da interação
  source              text        NOT NULL
                      CHECK (source IN ('nearby', 'search', 'map', 'recommendation')),

  -- Contexto de fluxo no momento da interação (desnormalizado para analytics)
  flow_at_event       text,
  score_at_event      int,

  -- Contexto temporal
  hour_of_day         int         NOT NULL CHECK (hour_of_day BETWEEN 0 AND 23),
  day_of_week         int         NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  is_weekend          boolean     NOT NULL DEFAULT false,
  is_holiday          boolean     NOT NULL DEFAULT false,

  created_at          timestamptz NOT NULL DEFAULT now()
);

-- ─── Índices ──────────────────────────────────────────────────────────────────

-- Query principal: buscar sinais de um local em ordem cronológica
CREATE INDEX IF NOT EXISTS idx_lus_location_time
  ON location_user_signals (location_id, created_at DESC);

-- Análise por tipo de evento
CREATE INDEX IF NOT EXISTS idx_lus_event_type
  ON location_user_signals (event_type, created_at DESC);

-- Análise de padrões por horário/dia (para "melhor horário" futuro)
CREATE INDEX IF NOT EXISTS idx_lus_temporal
  ON location_user_signals (hour_of_day, day_of_week);

-- Análise de abandono: dismiss por local + horário
CREATE INDEX IF NOT EXISTS idx_lus_dismiss
  ON location_user_signals (location_id, event_type, hour_of_day)
  WHERE event_type = 'dismiss';

-- ─── RLS ──────────────────────────────────────────────────────────────────────
-- App usa anon key. INSERT aberto (dados de comportamento são anônimos).
-- SELECT restrito para análise interna (futuro: via service_role ou painel admin).

ALTER TABLE location_user_signals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "signals_insert_anon"
  ON location_user_signals FOR INSERT
  WITH CHECK (true);

CREATE POLICY "signals_select_anon"
  ON location_user_signals FOR SELECT
  USING (true);

-- ─── View analítica: intenção agregada por local + hora ───────────────────────
-- Útil para dashboards futuros e para alimentar ajuste do crowd_score.

CREATE OR REPLACE VIEW location_intent_summary AS
SELECT
  location_id,
  hour_of_day,
  day_of_week,
  COUNT(*)                                      AS total_signals,
  ROUND(AVG(intent_score), 1)                   AS avg_intent,
  COUNT(*) FILTER (WHERE event_type = 'dismiss') AS dismissals,
  COUNT(*) FILTER (WHERE event_type = 'navigate') AS navigations,
  COUNT(*) FILTER (WHERE event_type = 'click')    AS clicks,
  ROUND(AVG(dwell_time_seconds) FILTER (WHERE dwell_time_seconds IS NOT NULL), 0) AS avg_dwell_seconds
FROM location_user_signals
GROUP BY location_id, hour_of_day, day_of_week;

-- ─── Notas de retenção ────────────────────────────────────────────────────────
-- Diferente de location_metrics (que retém só 6 snapshots), location_user_signals
-- tem valor analítico acumulado. Não aplicar limpeza automática por enquanto.
-- Revisar após 30 dias de coleta para avaliar volume e adicionar particionamento
-- por mês se necessário:
--
--   ALTER TABLE location_user_signals
--   PARTITION BY RANGE (created_at);
