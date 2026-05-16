-- =============================================================================
-- GoWait — Evolução de Schema: markets → locations
-- Migration: schema_locations_rename
--
-- Objetivo:
--   Tornar a arquitetura agnóstica ao tipo de local, permitindo expansão
--   para farmácias, varejo, serviços, etc. sem mudanças estruturais.
--
-- Mudanças:
--   1. Renomear tabela  markets       → locations
--   2. Renomear tabela  market_metrics → location_metrics
--   3. Renomear coluna  market_type   → segment   (subcategoria técnica do score)
--   4. Renomear coluna  market_id     → location_id (FK em location_metrics)
--   5. Adicionar coluna vertical      (categoria de produto visível ao usuário)
--   6. Recriar funções SQL com novos nomes de tabela/coluna
-- =============================================================================

-- ─── 1. Renomear tabelas ──────────────────────────────────────────────────────

ALTER TABLE markets        RENAME TO locations;
ALTER TABLE market_metrics RENAME TO location_metrics;

-- ─── 2. Renomear colunas ──────────────────────────────────────────────────────

ALTER TABLE locations        RENAME COLUMN market_type TO segment;
ALTER TABLE location_metrics RENAME COLUMN market_id   TO location_id;

-- ─── 3. Adicionar coluna vertical em locations ────────────────────────────────
--
-- vertical = categoria de produto visível ao usuário
--   'mercado'   → supermercados, atacados, mercearias
--   'farmácia'  → farmácias e drogarias
--   'varejo'    → lojas de roupas, eletrônicos, etc.
--   'serviços'  → bancos, cartórios, etc.
--   'alimentação'→ restaurantes, lanchonetes
--
ALTER TABLE locations ADD COLUMN IF NOT EXISTS vertical text;

-- Popular vertical para registros existentes (todos são mercados atualmente)
UPDATE locations SET vertical = 'mercado' WHERE vertical IS NULL;

-- ─── 4. Adicionar vertical em location_metrics (desnormalizado para analytics) ─

ALTER TABLE location_metrics ADD COLUMN IF NOT EXISTS vertical text;

UPDATE location_metrics lm
SET vertical = l.vertical
FROM locations l
WHERE lm.location_id = l.id;

-- ─── 5. Recriar funções SQL com novos nomes ───────────────────────────────────

-- Drop necessário pois o Postgres não permite renomear parâmetros via CREATE OR REPLACE
DROP FUNCTION IF EXISTS calculate_crowd_score(text,text,text,numeric,integer,boolean,boolean,integer);
DROP FUNCTION IF EXISTS compute_trend(uuid);
DROP FUNCTION IF EXISTS run_market_snapshot();

CREATE OR REPLACE FUNCTION calculate_crowd_score(
  p_segment         text,
  p_price_level     text,
  p_size            text,
  p_base_factor     numeric,
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
  IF p_base_factor IS NOT NULL THEN
    v_score := v_score + (p_base_factor - 50) * 0.3;
  END IF;

  v_score := v_score + CASE
    WHEN p_hour BETWEEN  7 AND  8 THEN  8
    WHEN p_hour BETWEEN  9 AND 10 THEN 12
    WHEN p_hour BETWEEN 11 AND 13 THEN 18
    WHEN p_hour BETWEEN 14 AND 16 THEN  8
    WHEN p_hour BETWEEN 17 AND 19 THEN 25
    WHEN p_hour BETWEEN 20 AND 21 THEN 12
    WHEN p_hour IN (22, 23)        THEN  5
    ELSE 0
  END;

  IF p_is_weekend  THEN v_score := v_score + 20; END IF;
  IF p_is_holiday  THEN v_score := v_score + 25; END IF;
  IF p_day_of_month <= 5 THEN v_score := v_score + 10; END IF;

  v_type_mod := CASE p_segment
    WHEN 'atacado'      THEN CASE WHEN p_is_weekend THEN 20 ELSE  8 END
    WHEN 'supermercado' THEN CASE WHEN p_is_weekend THEN  5 ELSE  0 END
    WHEN 'premium'      THEN CASE WHEN p_is_weekend THEN -5 ELSE -10 END
    WHEN 'convenience'  THEN -5
    WHEN 'discount'     THEN CASE WHEN p_is_weekend THEN 15 ELSE 12 END
    ELSE 0
  END;
  v_score := v_score + v_type_mod;

  v_score := v_score + CASE p_price_level
    WHEN 'low'     THEN  15
    WHEN 'high'    THEN -10
    WHEN 'premium' THEN -15
    ELSE 0
  END;

  v_score := v_score + CASE p_size
    WHEN 'small'       THEN  12
    WHEN 'large'       THEN  -8
    WHEN 'extra_large' THEN -15
    ELSE 0
  END;

  RETURN GREATEST(0, LEAST(100, ROUND(v_score)));
END;
$$;

-- compute_trend agora usa location_metrics + location_id
CREATE OR REPLACE FUNCTION compute_trend(p_location_id uuid)
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
    FROM location_metrics
    WHERE location_id = p_location_id
    ORDER BY created_at DESC
    LIMIT 6
  ) sub;

  v_n := COALESCE(ARRAY_LENGTH(v_scores, 1), 0);
  IF v_n < 4 THEN RETURN 'estável'; END IF;

  v_half    := v_n / 2;
  v_old_avg := (SELECT AVG(v) FROM UNNEST(v_scores[1:v_half])              AS v);
  v_new_avg := (SELECT AVG(v) FROM UNNEST(v_scores[v_n - v_half + 1:v_n]) AS v);
  v_delta   := v_new_avg - v_old_avg;

  RETURN CASE
    WHEN v_delta >  8 THEN 'subindo'
    WHEN v_delta < -8 THEN 'caindo'
    ELSE 'estável'
  END;
END;
$$;

-- run_location_snapshot: substitui run_market_snapshot
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
BEGIN
  FOR v_location IN
    SELECT id, segment, price_level, size, base_crowd_factor, slug, vertical
    FROM locations
  LOOP
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

  -- Manter apenas os 6 snapshots mais recentes por local
  DELETE FROM location_metrics
  WHERE id NOT IN (
    SELECT id
    FROM (
      SELECT id, ROW_NUMBER() OVER (PARTITION BY location_id ORDER BY created_at DESC) AS rn
      FROM location_metrics
    ) ranked
    WHERE rn <= 6
  );
END;
$$;

-- ─── 6. Atualizar pg_cron para nova função ────────────────────────────────────
-- Execute manualmente no SQL Editor após rodar esta migration:
--
--   SELECT cron.unschedule('market-snapshot');
--   SELECT cron.schedule(
--     'location-snapshot',
--     '*/15 * * * *',
--     'SELECT run_location_snapshot()'
--   );
--   SELECT * FROM cron.job;

-- ─── 7. Alias de compatibilidade (opcional — remover após deploy estável) ──────
-- Permite que código antigo ainda funcione durante a transição
-- CREATE VIEW markets        AS SELECT * FROM locations;
-- CREATE VIEW market_metrics AS SELECT location_id AS market_id, * FROM location_metrics;
