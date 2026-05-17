-- =============================================================================
-- GoWait — Integração de clima via weather_cache
-- Migration: weather_cache
--
-- O que cria:
--   1. Tabela weather_cache: estado atual do clima por cidade
--   2. calculate_crowd_score() — novo parâmetro p_weather (10 → 11 params)
--      Score: chuva +15 pts, frio/calor +8 pts
--   3. compute_trend() — repassa p_weather (usamos NULL: trend não muda com clima)
--   4. run_location_snapshot() — lê weather_cache e passa ao score
--
-- Como funciona o ciclo:
--   1. Edge Function `weather-sync` roda a cada 30 min → upserta weather_cache
--   2. pg_cron dispara run_location_snapshot() a cada 15 min
--   3. run_location_snapshot() lê weather_cache (máx 2h de idade) e passa ao score
--   4. Se weather_cache estiver vazio ou stale → weather = NULL → sem alteração no score
--
-- Pré-requisito:
--   Criar secret OPENWEATHER_API_KEY no Supabase Dashboard > Edge Functions > Secrets
--   (chave gratuita em https://openweathermap.org/api)
-- =============================================================================


-- ─── 1. Tabela: weather_cache ─────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS weather_cache (
  city        text PRIMARY KEY,
  condition   text NOT NULL
    CHECK (condition IN ('rain', 'cold', 'hot', 'clear')),
  temp_c      numeric,
  raw_main    text,       -- valor bruto da API (ex: "Rain", "Clear") para debug
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE weather_cache IS
  'Cache de condições climáticas por cidade, atualizado pela Edge Function weather-sync '
  'a cada 30 minutos. Uma linha por cidade monitorada.';

COMMENT ON COLUMN weather_cache.condition IS
  'Classificação simplificada: '
  'rain  = chuva/garoa/tempestade → +15 pts (corrida a lojas próximas); '
  'cold  = temperatura < 18°C     → +8 pts (as pessoas saem para estocar); '
  'hot   = temperatura > 30°C     → +8 pts (busca por ar condicionado); '
  'clear = céu limpo, temp. normal → sem ajuste.';

-- RLS: a Edge Function usa service role → acesso irrestrito.
-- Leitura de weather_cache pelo app direto não é necessária.
ALTER TABLE weather_cache ENABLE ROW LEVEL SECURITY;


-- ─── 2. Atualizar calculate_crowd_score() — adiciona p_weather ────────────────
--
-- Novo parâmetro opcional ao final (DEFAULT NULL → comportamento anterior inalterado).
-- Requer DROP da assinatura antiga antes de recriar (assinatura muda).

DROP FUNCTION IF EXISTS calculate_crowd_score(text,text,text,numeric,int,boolean,boolean,int,text);

CREATE OR REPLACE FUNCTION calculate_crowd_score(
  p_segment          text,
  p_price_level      text,
  p_size             text,
  p_base_factor      numeric,    -- 0–100 (50 = neutro)
  p_hour             int,
  p_is_weekend       boolean,
  p_is_holiday       boolean,
  p_day_of_month     int,
  p_location_context text DEFAULT 'standalone',
  p_weather          text DEFAULT NULL   -- 'rain' | 'cold' | 'hot' | 'clear' | NULL
) RETURNS int
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_score    numeric := 30;
  v_type_mod int;
BEGIN
  -- ── Fator estrutural base ─────────────────────────────────────────────────
  IF p_base_factor IS NOT NULL THEN
    v_score := v_score + (p_base_factor - 50) * 0.3;
  END IF;

  -- ── Padrão de pico por contexto de localização ───────────────────────────
  v_score := v_score + CASE p_location_context

    WHEN 'mall' THEN CASE
      WHEN p_hour BETWEEN  7 AND  9 THEN  2
      WHEN p_hour BETWEEN 10 AND 11 THEN  8
      WHEN p_hour BETWEEN 12 AND 13 THEN 15
      WHEN p_hour BETWEEN 14 AND 17 THEN 22   -- pico: tarde/família/lazer
      WHEN p_hour BETWEEN 18 AND 20 THEN 18
      WHEN p_hour = 21               THEN 10
      WHEN p_hour IN (22, 23)        THEN  4
      ELSE 0
    END

    WHEN 'comercial_street' THEN CASE
      WHEN p_hour BETWEEN  7 AND  8 THEN 12
      WHEN p_hour BETWEEN  9 AND 10 THEN 15
      WHEN p_hour BETWEEN 11 AND 13 THEN 25   -- pico: hora do almoço
      WHEN p_hour BETWEEN 14 AND 16 THEN 10
      WHEN p_hour BETWEEN 17 AND 18 THEN 20   -- pico 2: saída do trabalho
      WHEN p_hour BETWEEN 19 AND 20 THEN  8
      WHEN p_hour IN (21, 22, 23)    THEN  3
      ELSE 0
    END

    WHEN 'transit_hub' THEN CASE
      WHEN p_hour BETWEEN  5 AND  6 THEN 15
      WHEN p_hour BETWEEN  7 AND  8 THEN 22   -- pico: rush manhã
      WHEN p_hour BETWEEN  9 AND 10 THEN 10
      WHEN p_hour BETWEEN 11 AND 13 THEN 12
      WHEN p_hour BETWEEN 14 AND 16 THEN  8
      WHEN p_hour BETWEEN 17 AND 19 THEN 22   -- pico: rush tarde
      WHEN p_hour = 20               THEN 10
      WHEN p_hour IN (21, 22, 23)    THEN  5
      ELSE 0
    END

    ELSE -- 'standalone', 'residential', NULL → padrão
      CASE
        WHEN p_hour BETWEEN  7 AND  8 THEN  8
        WHEN p_hour BETWEEN  9 AND 10 THEN 12
        WHEN p_hour BETWEEN 11 AND 13 THEN 18
        WHEN p_hour BETWEEN 14 AND 16 THEN  8
        WHEN p_hour BETWEEN 17 AND 19 THEN 25  -- pico máximo
        WHEN p_hour BETWEEN 20 AND 21 THEN 12
        WHEN p_hour IN (22, 23)        THEN  5
        ELSE 0
      END

  END;

  -- ── Modificadores temporais ───────────────────────────────────────────────

  -- Fim de semana (por contexto)
  IF p_is_weekend THEN
    v_score := v_score + CASE p_location_context
      WHEN 'mall'             THEN 25
      WHEN 'residential'      THEN 22
      WHEN 'transit_hub'      THEN  8
      WHEN 'comercial_street' THEN 10
      ELSE 20   -- standalone
    END;
  END IF;

  -- Feriado
  IF p_is_holiday THEN v_score := v_score + 25; END IF;

  -- Efeito salário + quinzena (peso varia por segmento)
  -- Janela: dias 1–7 (salário mensal — 5º dia útil pode cair até dia 7)
  --         dias 13–16 (quinzena/adiantamento)
  IF p_day_of_month <= 7 OR p_day_of_month BETWEEN 13 AND 16 THEN
    v_score := v_score + CASE p_segment
      WHEN 'atacado'      THEN 18
      WHEN 'discount'     THEN 15
      WHEN 'supermercado' THEN 12
      WHEN 'convenience'  THEN  6
      WHEN 'premium'      THEN  4
      ELSE                     10
    END;
  END IF;

  -- ── Modificadores estruturais do local ───────────────────────────────────

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

  -- ── Modificador climático ─────────────────────────────────────────────────
  --
  -- Chuva: +15 pts — pessoas correm às lojas próximas para se abrigar/estocar
  -- Frio:  +8 pts  — comportamento de estoque, saída rápida
  -- Calor: +8 pts  — busca por ar condicionado dentro de lojas
  -- Limpo: sem ajuste
  v_score := v_score + CASE p_weather
    WHEN 'rain' THEN 15
    WHEN 'cold' THEN  8
    WHEN 'hot'  THEN  8
    ELSE 0
  END;

  RETURN GREATEST(0, LEAST(100, ROUND(v_score)));
END;
$$;


-- ─── 3. Atualizar compute_trend() — repassa weather NULL ─────────────────────
--
-- A tendência compara hora atual vs hora +1 com os mesmos parâmetros.
-- O clima é o mesmo nos dois momentos, então o delta não muda com p_weather.
-- Passamos NULL explicitamente para manter a assinatura consistente.

DROP FUNCTION IF EXISTS compute_trend(uuid);

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
  v_is_holiday  bool := false;
  v_score_now   int;
  v_score_next  int;
  v_delta       int;
BEGIN
  SELECT segment, price_level, size, base_crowd_factor, location_context
  INTO v_loc
  FROM locations
  WHERE id = p_location_id;

  IF NOT FOUND THEN RETURN 'estável'; END IF;

  -- Clima não afeta a tendência (delta hora a hora): passamos NULL nos dois scores
  v_score_now  := calculate_crowd_score(
    v_loc.segment, v_loc.price_level, v_loc.size, v_loc.base_crowd_factor,
    v_hour_now,  v_is_weekend, v_is_holiday, v_dom, v_loc.location_context, NULL
  );
  v_score_next := calculate_crowd_score(
    v_loc.segment, v_loc.price_level, v_loc.size, v_loc.base_crowd_factor,
    v_hour_next, v_is_weekend, v_is_holiday, v_dom, v_loc.location_context, NULL
  );

  v_delta := v_score_next - v_score_now;

  RETURN CASE
    WHEN v_delta >  5 THEN 'subindo'
    WHEN v_delta < -5 THEN 'caindo'
    ELSE 'estável'
  END;
END;
$$;


-- ─── 4. Atualizar run_location_snapshot() — lê weather_cache ─────────────────
--
-- Antes de processar os locais, busca o estado climático atual.
-- Se weather_cache estiver vazio ou desatualizado (> 2h), usa NULL → sem impacto.

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
  v_weather     text := NULL;
  v_score       int;
  v_flow        text;
  v_wait        text;
  v_trend       text;
  v_open        bool;
BEGIN
  -- Lê condição climática atual (máx 2h de idade)
  SELECT condition INTO v_weather
  FROM weather_cache
  WHERE updated_at > now() - interval '2 hours'
  ORDER BY updated_at DESC
  LIMIT 1;
  -- v_weather fica NULL se não houver entrada válida → sem impacto no score

  FOR v_location IN
    SELECT id, segment, price_level, size, base_crowd_factor,
           slug, vertical, location_context, checkout_count
    FROM locations
  LOOP
    v_open := is_location_open(v_location.id);
    UPDATE locations SET is_open = v_open WHERE id = v_location.id;
    CONTINUE WHEN NOT v_open;

    v_score := calculate_crowd_score(
      v_location.segment, v_location.price_level, v_location.size,
      v_location.base_crowd_factor, v_hour, v_is_weekend, v_is_holiday,
      v_dom, v_location.location_context, v_weather
    );

    v_flow  := crowd_score_to_flow(v_score);
    v_wait  := crowd_score_to_wait_time(
                 v_score,
                 v_location.checkout_count,
                 v_location.size
               );
    v_trend := compute_trend(v_location.id);

    INSERT INTO location_metrics (
      location_id, slug, vertical, crowd_score, flow, wait_time, trend,
      is_holiday, is_weekend, day_of_week, hour_of_day, weather
    ) VALUES (
      v_location.id, v_location.slug, v_location.vertical,
      v_score, v_flow, v_wait, v_trend,
      v_is_holiday, v_is_weekend, v_dow, v_hour, v_weather
    );

    UPDATE locations
    SET flow        = v_flow,
        wait_time   = v_wait,
        trend       = v_trend,
        crowd_score = v_score,
        snapshot_at = now()
    WHERE id = v_location.id;

  END LOOP;

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
