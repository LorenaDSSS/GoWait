-- =============================================================================
-- GoWait — Score efetivo blendado (heurística + inteligência)
-- Migration: blended_score
--
-- Problema resolvido:
--   O crowd_score exibido no app era 100% heurístico.
--   A intelligence_score era calculada mas não influenciava o display.
--
-- Solução:
--   run_location_snapshot() passa a usar um "score efetivo" blendado para
--   determinar flow, wait_time e o crowd_score gravado em locations.
--
--   O crowd_score em location_metrics permanece HEURÍSTICO PURO — é o input
--   da camada de inteligência. Misturar ali criaria feedback loop.
--
-- Regra de blend por confidence_level:
--   low    (< 10 sinais)   → 100% heurístico  (sem dados suficientes)
--   medium (10–49 sinais)  → 75% heurístico + 25% intelligence
--   high   (≥ 50 sinais)   → 50% heurístico + 50% intelligence
--
-- Transição automática: quanto mais usuários interagem, mais peso a IA ganha.
-- =============================================================================

CREATE OR REPLACE FUNCTION run_location_snapshot()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_location      RECORD;
  v_now           timestamp := now() AT TIME ZONE 'America/Sao_Paulo';
  v_hour          int  := EXTRACT(hour  FROM v_now)::int;
  v_dow           int  := EXTRACT(dow   FROM v_now)::int;
  v_dom           int  := EXTRACT(day   FROM v_now)::int;
  v_is_weekend    bool := v_dow IN (0, 6);
  v_is_holiday    bool := false;
  v_weather       text := NULL;
  v_score         int;   -- heurístico puro (vai para location_metrics)
  v_intel_score   int;   -- intelligence_score da última rodada da IA
  v_confidence    text;  -- 'low' | 'medium' | 'high'
  v_effective     int;   -- score blendado (vai para locations + flow/wait)
  v_flow          text;
  v_wait          text;
  v_trend         text;
  v_open          bool;
BEGIN
  -- Lê condição climática atual (máx 2h de idade)
  SELECT condition INTO v_weather
  FROM weather_cache
  WHERE updated_at > now() - interval '2 hours'
  ORDER BY updated_at DESC
  LIMIT 1;

  FOR v_location IN
    SELECT id, segment, price_level, size, base_crowd_factor,
           slug, vertical, location_context, checkout_count
    FROM locations
  LOOP
    v_open := is_location_open(v_location.id);
    UPDATE locations SET is_open = v_open WHERE id = v_location.id;
    CONTINUE WHEN NOT v_open;

    -- ── 1. Score heurístico puro ─────────────────────────────────────────────
    v_score := calculate_crowd_score(
      v_location.segment, v_location.price_level, v_location.size,
      v_location.base_crowd_factor, v_hour, v_is_weekend, v_is_holiday,
      v_dom, v_location.location_context, v_weather
    );

    -- ── 2. Lê intelligence_score mais recente (se existir) ───────────────────
    SELECT intelligence_score, confidence_level
    INTO v_intel_score, v_confidence
    FROM location_intelligence
    WHERE location_id = v_location.id;

    -- ── 3. Blend baseado em confiança ────────────────────────────────────────
    --
    -- Se não houver intelligence ainda → usa heurístico puro.
    -- À medida que mais usuários interagem, a IA ganha peso automaticamente.
    v_effective := CASE
      WHEN v_intel_score IS NULL OR v_confidence = 'low' THEN
        v_score                                                    -- 100% heurístico

      WHEN v_confidence = 'medium' THEN
        ROUND(0.75 * v_score + 0.25 * v_intel_score)::int         -- 75/25

      WHEN v_confidence = 'high' THEN
        ROUND(0.50 * v_score + 0.50 * v_intel_score)::int         -- 50/50

      ELSE v_score
    END;

    -- Garante que o score efetivo permanece dentro do range válido
    v_effective := GREATEST(0, LEAST(100, v_effective));

    -- ── 4. Deriva flow, wait e trend do score EFETIVO ────────────────────────
    v_flow  := crowd_score_to_flow(v_effective);
    v_wait  := crowd_score_to_wait_time(
                 v_effective,
                 v_location.checkout_count,
                 v_location.size
               );
    v_trend := compute_trend(v_location.id);

    -- ── 5. Grava heurístico PURO em location_metrics (input da IA) ───────────
    INSERT INTO location_metrics (
      location_id, slug, vertical, crowd_score, flow, wait_time, trend,
      is_holiday, is_weekend, day_of_week, hour_of_day, weather
    ) VALUES (
      v_location.id, v_location.slug, v_location.vertical,
      v_score,      -- heurístico puro — não contaminado pelo blend
      v_flow, v_wait, v_trend,
      v_is_holiday, v_is_weekend, v_dow, v_hour, v_weather
    );

    -- ── 6. Grava score EFETIVO em locations (o que o app exibe) ─────────────
    UPDATE locations
    SET flow        = v_flow,
        wait_time   = v_wait,
        trend       = v_trend,
        crowd_score = v_effective,   -- blendado
        snapshot_at = now()
    WHERE id = v_location.id;

  END LOOP;

  -- Retém apenas os 6 snapshots mais recentes por local
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

COMMENT ON FUNCTION run_location_snapshot() IS
  'Snapshot a cada 15 min. Calcula crowd_score heurístico puro (gravado em '
  'location_metrics como input da IA) e um score efetivo blendado (gravado em '
  'locations para exibição no app). O blend aumenta o peso da IA conforme a '
  'confidence_level sobe: low=100% heurístico, medium=75/25, high=50/50.';
