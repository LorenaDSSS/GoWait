-- =============================================================================
-- GoWait — Contexto de localização + efeito quinzena
-- Migration: location_context
--
-- Problema:
--   O modelo trata todos os locais com o mesmo padrão de pico por hora.
--   Um mercado dentro de um shopping e um mercado de bairro residencial
--   têm padrões completamente diferentes — mas recebiam o mesmo score.
--
-- Solução 1 — location_context:
--   Nova coluna que classifica o entorno do local. Ajusta os blocos de hora
--   dentro de calculate_crowd_score() para refletir a realidade de cada contexto:
--
--   standalone        → pico às 17h–19h (padrão atual — bairro, sem vizinhos)
--   residential       → igual ao standalone + bônus extra no fim de semana
--   mall              → pico às 14h–17h (fluxo do shopping, tarde/família)
--   comercial_street  → pico às 11h–13h + 17h–18h (almoço + saída do trabalho)
--   transit_hub       → picos duplos 6h–8h e 17h–19h (ciclo de transporte)
--
-- Solução 2 — efeito quinzena:
--   O modelo capturava o efeito salário (dias 1–5) mas ignorava o dia 15.
--   No Brasil, boa parte dos trabalhadores recebe quinzenalmente.
--   Fix simples: +10 pts nos dias 13–16 (mesma intensidade que o início do mês).
--
-- Compatibilidade:
--   • location_context DEFAULT 'standalone' → todos os locais existentes
--     mantêm o comportamento atual até serem atualizados no cadastro.
--   • calculate_crowd_score() recebe novo parâmetro (9 → 10 params).
--     A versão antiga de 9 params é removida nesta migration.
--   • compute_trend() e run_location_snapshot() são reescritos para passar
--     o novo parâmetro.
-- =============================================================================


-- ─── 1. Nova coluna: location_context ────────────────────────────────────────

ALTER TABLE locations
  ADD COLUMN IF NOT EXISTS location_context text
    NOT NULL DEFAULT 'standalone'
    CHECK (location_context IN (
      'standalone', 'residential', 'mall', 'comercial_street', 'transit_hub'
    ));

-- Comentário de referência para o cadastro:
COMMENT ON COLUMN locations.location_context IS
  'Contexto de localização do estabelecimento. '
  'standalone = bairro isolado; '
  'residential = área residencial densa; '
  'mall = dentro de shopping/centro comercial; '
  'comercial_street = rua comercial ou centro urbano; '
  'transit_hub = próximo a terminal de ônibus, metrô ou trem.';


-- ─── 2. Reescrever calculate_crowd_score() com context-aware peak hours ───────
--
-- Mudanças:
--   a) Novo parâmetro p_location_context (último, para não quebrar chamadas
--      que usam argumentos posicionais de versões antigas — já não existem)
--   b) Bloco de hora substituído por CASE por contexto
--   c) Efeito quinzena: dias 13–16 também valem +10 pts

-- Remove assinatura antiga (9 params) antes de recriar com 10
DROP FUNCTION IF EXISTS calculate_crowd_score(text,text,text,numeric,integer,boolean,boolean,integer);

CREATE OR REPLACE FUNCTION calculate_crowd_score(
  p_segment          text,
  p_price_level      text,
  p_size             text,
  p_base_factor      numeric,    -- 0–100 (50 = neutro)
  p_hour             int,
  p_is_weekend       boolean,
  p_is_holiday       boolean,
  p_day_of_month     int,
  p_location_context text DEFAULT 'standalone'
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
  --
  -- standalone / residential (default):
  --   Bairro residencial, mercado independente. Pico na volta do trabalho.
  --
  -- mall:
  --   Dentro de shopping. Abre mais tarde, pico no período da tarde.
  --   Clientes vêm para lazer + compras, não só para compras rápidas.
  --
  -- commercial_street:
  --   Rua comercial, centro urbano, escritórios próximos.
  --   Pico no horário de almoço + saída do trabalho.
  --
  -- transit_hub:
  --   Próximo a terminal de ônibus/metrô/trem.
  --   Dois picos nítidos: entrada e saída do trabalho.

  v_score := v_score + CASE p_location_context

    WHEN 'mall' THEN CASE
      WHEN p_hour BETWEEN  7 AND  9 THEN  2   -- mall ainda fechando/abrindo
      WHEN p_hour BETWEEN 10 AND 11 THEN  8   -- início do movimento
      WHEN p_hour BETWEEN 12 AND 13 THEN 15   -- almoço no mall
      WHEN p_hour BETWEEN 14 AND 17 THEN 22   -- ← pico: tarde/família/lazer
      WHEN p_hour BETWEEN 18 AND 20 THEN 18   -- ainda forte
      WHEN p_hour = 21               THEN 10
      WHEN p_hour IN (22, 23)        THEN  4
      ELSE 0
    END

    WHEN 'comercial_street' THEN CASE
      WHEN p_hour BETWEEN  7 AND  8 THEN 12   -- trabalhadores chegando
      WHEN p_hour BETWEEN  9 AND 10 THEN 15   -- expediente iniciado
      WHEN p_hour BETWEEN 11 AND 13 THEN 25   -- ← pico: hora do almoço
      WHEN p_hour BETWEEN 14 AND 16 THEN 10   -- retorno do almoço
      WHEN p_hour BETWEEN 17 AND 18 THEN 20   -- ← pico 2: saída do trabalho
      WHEN p_hour BETWEEN 19 AND 20 THEN  8   -- decaindo
      WHEN p_hour IN (21, 22, 23)    THEN  3
      ELSE 0
    END

    WHEN 'transit_hub' THEN CASE
      WHEN p_hour BETWEEN  5 AND  6 THEN 15   -- primeiros ônibus
      WHEN p_hour BETWEEN  7 AND  8 THEN 22   -- ← pico: rush manhã
      WHEN p_hour BETWEEN  9 AND 10 THEN 10
      WHEN p_hour BETWEEN 11 AND 13 THEN 12
      WHEN p_hour BETWEEN 14 AND 16 THEN  8
      WHEN p_hour BETWEEN 17 AND 19 THEN 22   -- ← pico: rush tarde
      WHEN p_hour = 20               THEN 10
      WHEN p_hour IN (21, 22, 23)    THEN  5
      ELSE 0
    END

    ELSE -- 'standalone', 'residential', NULL → padrão original
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

  -- Fim de semana
  IF p_is_weekend THEN
    v_score := v_score + CASE p_location_context
      WHEN 'mall'             THEN 25  -- shopping superlota no fim de semana
      WHEN 'residential'      THEN 22  -- bairro residencial ativo no fim de semana
      WHEN 'transit_hub'      THEN  8  -- trânsito de transporte cai no fim de semana
      WHEN 'comercial_street' THEN 10  -- fluxo diferente, menos corporativo
      ELSE 20                          -- standalone: padrão
    END;
  END IF;

  -- Feriado
  IF p_is_holiday THEN v_score := v_score + 25; END IF;

  -- Início do mês (efeito salário: dias 1–5) + quinzena (dias 13–16)
  -- Trabalhadores recebem no início e/ou no dia 15 — ambos geram pico
  IF p_day_of_month <= 5 OR p_day_of_month BETWEEN 13 AND 16 THEN
    v_score := v_score + 10;
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

  RETURN GREATEST(0, LEAST(100, ROUND(v_score)));
END;
$$;


-- ─── 3. Reescrever compute_trend() com location_context ──────────────────────
--
-- Lê location_context de locations e repassa para calculate_crowd_score().
-- Lógica preditiva mantida: score(hora atual) vs score(próxima hora).

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

  v_score_now  := calculate_crowd_score(
    v_loc.segment, v_loc.price_level, v_loc.size, v_loc.base_crowd_factor,
    v_hour_now,  v_is_weekend, v_is_holiday, v_dom, v_loc.location_context
  );
  v_score_next := calculate_crowd_score(
    v_loc.segment, v_loc.price_level, v_loc.size, v_loc.base_crowd_factor,
    v_hour_next, v_is_weekend, v_is_holiday, v_dom, v_loc.location_context
  );

  v_delta := v_score_next - v_score_now;

  RETURN CASE
    WHEN v_delta >  5 THEN 'subindo'
    WHEN v_delta < -5 THEN 'caindo'
    ELSE 'estável'
  END;
END;
$$;


-- ─── 4. Reescrever run_location_snapshot() com location_context ──────────────

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
    SELECT id, segment, price_level, size, base_crowd_factor,
           slug, vertical, location_context
    FROM locations
  LOOP
    v_open := is_location_open(v_location.id);
    UPDATE locations SET is_open = v_open WHERE id = v_location.id;
    CONTINUE WHEN NOT v_open;

    v_score := calculate_crowd_score(
      v_location.segment, v_location.price_level, v_location.size,
      v_location.base_crowd_factor, v_hour, v_is_weekend, v_is_holiday,
      v_dom, v_location.location_context
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


-- ─── Referência: como atualizar location_context no cadastro ─────────────────
--
-- Após rodar esta migration, atualize os locais existentes via SQL Editor
-- ou via painel Supabase (Table Editor > locations):
--
--   UPDATE locations SET location_context = 'mall'
--   WHERE name ILIKE '%shopping%' OR name ILIKE '%center%';
--
--   UPDATE locations SET location_context = 'transit_hub'
--   WHERE name ILIKE '%terminal%' OR name ILIKE '%rodoviária%';
--
--   UPDATE locations SET location_context = 'comercial_street'
--   WHERE name ILIKE '%centro%';
--
-- Todos os demais permanecem 'standalone' (comportamento atual).
--
-- ─── Verificação após rodar ───────────────────────────────────────────────────
--
-- Testar padrão de pico por contexto (substitua pelo horário atual):
--
--   SELECT
--     l.name,
--     l.location_context,
--     calculate_crowd_score(l.segment, l.price_level, l.size,
--       l.base_crowd_factor, 14, false, false, 10, l.location_context) AS score_14h,
--     calculate_crowd_score(l.segment, l.price_level, l.size,
--       l.base_crowd_factor, 17, false, false, 10, l.location_context) AS score_17h,
--     calculate_crowd_score(l.segment, l.price_level, l.size,
--       l.base_crowd_factor, 12, false, false, 10, l.location_context) AS score_12h
--   FROM locations l;
--
-- standalone/residential: score_17h > score_12h > score_14h ✓
-- mall:                   score_14h ≥ score_17h > score_12h ✓
-- comercial_street:       score_12h > score_17h > score_14h ✓
-- transit_hub:            score_17h ≈ score_12h > score_14h ✓
