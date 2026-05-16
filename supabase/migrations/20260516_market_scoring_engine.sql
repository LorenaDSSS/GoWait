-- =============================================================================
-- GoWait — Engine de Score Inteligente
-- Migration: market_scoring_engine
--
-- O que cria:
--   1. Funções SQL para calcular crowd_score, flow, wait_time (fallback puro-SQL)
--   2. Função run_market_snapshot() — usada pelo pg_cron
--   3. Agendamento via pg_cron (a cada 15 minutos)
--
-- Pré-requisitos (ativar no Dashboard > Database > Extensions):
--   • pg_cron
--
-- A Edge Function (supabase/functions/market-snapshot) é o caminho preferido
-- para integrações externas (clima, feriados, etc.).
-- As funções SQL abaixo são o fallback confiável que roda diretamente no banco.
-- =============================================================================

-- ─── 1. Função: crowd_score heurístico ───────────────────────────────────────

CREATE OR REPLACE FUNCTION calculate_crowd_score(
  p_market_type     text,
  p_price_level     text,
  p_size            text,
  p_base_factor     numeric,  -- 0–100 (50 = neutro)
  p_hour            int,
  p_is_weekend      boolean,
  p_is_holiday      boolean,
  p_day_of_month    int
) RETURNS int
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_score     numeric := 30;
  v_type_mod  int;
BEGIN
  -- Fator estrutural do mercado
  IF p_base_factor IS NOT NULL THEN
    v_score := v_score + (p_base_factor - 50) * 0.3;
  END IF;

  -- Horário do dia
  v_score := v_score + CASE
    WHEN p_hour BETWEEN  7 AND  8 THEN  8
    WHEN p_hour BETWEEN  9 AND 10 THEN 12
    WHEN p_hour BETWEEN 11 AND 13 THEN 18
    WHEN p_hour BETWEEN 14 AND 16 THEN  8
    WHEN p_hour BETWEEN 17 AND 19 THEN 25  -- pico máximo
    WHEN p_hour BETWEEN 20 AND 21 THEN 12
    WHEN p_hour IN (22, 23)        THEN  5
    ELSE 0
  END;

  -- Final de semana
  IF p_is_weekend  THEN v_score := v_score + 20; END IF;

  -- Feriado
  IF p_is_holiday  THEN v_score := v_score + 25; END IF;

  -- Início do mês (efeito salário: dias 1–5)
  IF p_day_of_month <= 5 THEN v_score := v_score + 10; END IF;

  -- Tipo de mercado
  v_type_mod := CASE p_market_type
    WHEN 'atacado'      THEN CASE WHEN p_is_weekend THEN 20 ELSE  8 END
    WHEN 'supermercado' THEN CASE WHEN p_is_weekend THEN  5 ELSE  0 END
    WHEN 'premium'      THEN CASE WHEN p_is_weekend THEN -5 ELSE -10 END
    WHEN 'convenience'  THEN -5
    WHEN 'discount'     THEN CASE WHEN p_is_weekend THEN 15 ELSE 12 END
    ELSE 0
  END;
  v_score := v_score + v_type_mod;

  -- Faixa de preço
  v_score := v_score + CASE p_price_level
    WHEN 'low'     THEN  15
    WHEN 'high'    THEN -10
    WHEN 'premium' THEN -15
    ELSE 0
  END;

  -- Tamanho (mercados menores → experiência mais intensa de lotação)
  v_score := v_score + CASE p_size
    WHEN 'small'       THEN  12
    WHEN 'large'       THEN  -8
    WHEN 'extra_large' THEN -15
    ELSE 0
  END;

  RETURN GREATEST(0, LEAST(100, ROUND(v_score)));
END;
$$;

-- ─── 2. crowd_score → flow ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION crowd_score_to_flow(p_score int)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_score <= 35 THEN 'baixo'
    WHEN p_score <= 70 THEN 'médio'
    ELSE 'alto'
  END;
$$;

-- ─── 3. crowd_score → wait_time ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION crowd_score_to_wait_time(p_score int)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_minutes int;
BEGIN
  -- Mapeamento linear dentro da faixa de cada fluxo
  v_minutes := CASE
    WHEN p_score <= 35 THEN  5 + ROUND(( p_score::numeric          / 35)  *  5)  -- 5–10 min
    WHEN p_score <= 70 THEN 12 + ROUND(((p_score - 36)::numeric    / 34)  *  8)  -- 12–20 min
    ELSE                     25 + ROUND(((p_score - 71)::numeric   / 29)  * 15)  -- 25–40 min
  END;
  RETURN v_minutes || ' min';
END;
$$;

-- ─── 4. histórico de scores → trend ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION compute_trend(p_market_id uuid)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_scores  int[];
  v_n       int;
  v_half    int;
  v_old_avg numeric;
  v_new_avg numeric;
  v_delta   numeric;
BEGIN
  SELECT ARRAY_AGG(crowd_score ORDER BY created_at ASC)
  INTO v_scores
  FROM (
    SELECT crowd_score, created_at
    FROM market_metrics
    WHERE market_id = p_market_id
    ORDER BY created_at DESC
    LIMIT 6
  ) sub;

  v_n := COALESCE(ARRAY_LENGTH(v_scores, 1), 0);
  IF v_n < 4 THEN RETURN 'estável'; END IF;

  v_half    := v_n / 2;
  v_old_avg := (SELECT AVG(v) FROM UNNEST(v_scores[1:v_half])            AS v);
  v_new_avg := (SELECT AVG(v) FROM UNNEST(v_scores[v_n - v_half + 1:v_n]) AS v);
  v_delta   := v_new_avg - v_old_avg;

  RETURN CASE
    WHEN v_delta >  8 THEN 'subindo'
    WHEN v_delta < -8 THEN 'caindo'
    ELSE 'estável'
  END;
END;
$$;

-- ─── 5. Função principal: run_market_snapshot ─────────────────────────────────

CREATE OR REPLACE FUNCTION run_market_snapshot()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_market      RECORD;
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
BEGIN
  FOR v_market IN
    SELECT id, market_type, price_level, size, base_crowd_factor, slug
    FROM markets
  LOOP
    v_score := calculate_crowd_score(
      v_market.market_type,
      v_market.price_level,
      v_market.size,
      v_market.base_crowd_factor,
      v_hour,
      v_is_weekend,
      v_is_holiday,
      v_dom
    );

    v_flow  := crowd_score_to_flow(v_score);
    v_wait  := crowd_score_to_wait_time(v_score);
    v_trend := compute_trend(v_market.id);

    -- Inserir snapshot histórico
    INSERT INTO market_metrics (
      market_id, slug, crowd_score, flow, wait_time, trend,
      is_holiday, is_weekend, day_of_week, hour_of_day, weather
    ) VALUES (
      v_market.id, v_market.slug, v_score, v_flow, v_wait, v_trend,
      v_is_holiday, v_is_weekend, v_dow, v_hour, NULL
    );

    -- Atualizar estado atual do mercado
    UPDATE markets
    SET flow      = v_flow,
        wait_time = v_wait,
        trend     = v_trend
    WHERE id = v_market.id;

  END LOOP;

  -- Manter apenas os 6 snapshots mais recentes por mercado
  -- (6 registros = ~1h30 de histórico, suficiente para calcular trend)
  DELETE FROM market_metrics
  WHERE id NOT IN (
    SELECT id
    FROM (
      SELECT id, ROW_NUMBER() OVER (PARTITION BY market_id ORDER BY created_at DESC) AS rn
      FROM market_metrics
    ) ranked
    WHERE rn <= 6
  );
END;
$$;

-- ─── 6. Agendamento pg_cron ───────────────────────────────────────────────────
-- Ativa pg_cron no Dashboard: Database > Extensions > pg_cron
--
-- Após ativar a extensão, execute manualmente no SQL Editor:
--
--   SELECT cron.schedule(
--     'market-snapshot',   -- nome do job
--     '*/15 * * * *',      -- a cada 15 minutos
--     'SELECT run_market_snapshot()'
--   );
--
-- Para verificar jobs agendados:
--   SELECT * FROM cron.job;
--
-- Para remover:
--   SELECT cron.unschedule('market-snapshot');
--
-- Alternativa via Supabase Dashboard:
--   Database > Cron Jobs > New Cron Job
--   → Function: run_market_snapshot
--   → Schedule: */15 * * * *

-- ─── 7. Estrutura preparada para extensões futuras ───────────────────────────
--
-- holidays (feriados):
--   CREATE TABLE holidays (
--     date date PRIMARY KEY,
--     name text,
--     city text  -- NULL = nacional
--   );
--   -- Integrar na função: IF EXISTS (SELECT 1 FROM holidays WHERE date = CURRENT_DATE) THEN ...
--
-- weather_cache (clima):
--   CREATE TABLE weather_cache (
--     city        text PRIMARY KEY,
--     condition   text,   -- 'rain' | 'clear' | 'cold' | etc.
--     updated_at  timestamptz DEFAULT now()
--   );
--
-- events (eventos regionais):
--   CREATE TABLE events (
--     id          uuid DEFAULT gen_random_uuid() PRIMARY KEY,
--     name        text,
--     city        text,
--     starts_at   timestamptz,
--     ends_at     timestamptz,
--     crowd_bonus int DEFAULT 0
--   );
