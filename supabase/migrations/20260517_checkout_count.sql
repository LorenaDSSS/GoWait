-- =============================================================================
-- GoWait — checkout_count: wait_time realista por número de caixas
-- Migration: checkout_count
--
-- Problema:
--   crowd_score_to_wait_time() usa apenas o score (0-100) para estimar espera.
--   Um supermercado com 20 caixas abertos e um com 3 caixas têm wait_time
--   completamente diferente ao mesmo nível de fluxo — o modelo ignorava isso.
--
-- Solução:
--   Nova coluna checkout_count em locations.
--   crowd_score_to_wait_time() ganha parâmetros opcionais: checkout_count + size.
--   O fator de ajuste é calculado como:
--
--     fator = caixas_referencia_do_porte / checkout_count_real
--
--   Valores de referência por porte (caixas "normais" para cada tamanho):
--     small       → 2 caixas
--     medium      → 5 caixas
--     large       → 10 caixas
--     extra_large → 18 caixas
--
--   Exemplos reais:
--     Assaí (extra_large, 8 caixas abertos) fator = 18/8 = 2.25
--       → wait_time × 2.25 — fila relevante mesmo com fluxo médio
--     Mercadinho de bairro (small, 1 caixa) fator = 2/1 = 2.0
--       → wait_time dobra quando há movimento
--     Supermercado grande (large, 15 caixas) fator = 10/15 = 0.67
--       → wait_time cai 33% — flui melhor que o modelo previa
--
--   Sem checkout_count preenchido → comportamento atual inalterado (fator = 1.0)
--
-- Compatibilidade:
--   backward-compatible: checkout_count é optional (DEFAULT NULL).
--   run_location_snapshot() atualizado para passar o novo parâmetro.
-- =============================================================================


-- ─── 1. Nova coluna: checkout_count ──────────────────────────────────────────

ALTER TABLE locations
  ADD COLUMN IF NOT EXISTS checkout_count int DEFAULT NULL
    CHECK (checkout_count IS NULL OR checkout_count > 0);

COMMENT ON COLUMN locations.checkout_count IS
  'Número típico de caixas abertos em pico. NULL = usa fórmula padrão sem ajuste. '
  'Referências: small=2, medium=5, large=10, extra_large=18.';


-- ─── 2. Reescrever crowd_score_to_wait_time() com ajuste por caixas ──────────
--
-- Assinatura nova tem 3 params, os 2 novos são opcionais.
-- A versão antiga (1 param) é mantida como overload para compatibilidade
-- com qualquer chamada direta que ainda use só o score.

-- Remove a versão antiga de 1 param antes de recriar
DROP FUNCTION IF EXISTS crowd_score_to_wait_time(int);

CREATE OR REPLACE FUNCTION crowd_score_to_wait_time(
  p_score          int,
  p_checkout_count int  DEFAULT NULL,
  p_size           text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_base_minutes  numeric;
  v_ref_checkouts numeric;
  v_factor        numeric := 1.0;
  v_final_minutes int;
BEGIN
  -- ── Score → minutos base (fórmula original, inalterada) ──────────────────
  v_base_minutes := CASE
    WHEN p_score <= 55 THEN  5 + ROUND(( p_score::numeric          / 55)  *  5)  -- 5–10 min
    WHEN p_score <= 75 THEN 12 + ROUND(((p_score - 56)::numeric    / 19)  *  8)  -- 12–20 min
    ELSE                     25 + ROUND(((p_score - 76)::numeric   / 24)  * 15)  -- 25–40 min
  END;

  -- ── Ajuste por checkout_count ─────────────────────────────────────────────
  --
  -- Apenas aplica o fator se checkout_count for informado.
  -- Se não informado, retorna exatamente o comportamento anterior.
  IF p_checkout_count IS NOT NULL AND p_checkout_count > 0 THEN

    -- Referência de caixas por porte do local
    v_ref_checkouts := CASE p_size
      WHEN 'small'       THEN  2
      WHEN 'large'       THEN 10
      WHEN 'extra_large' THEN 18
      ELSE                    5   -- medium ou null → referência média
    END;

    -- Fator = quanto o local desvia da referência do seu porte
    -- Mais caixas que o normal  → fator < 1 → espera menor
    -- Menos caixas que o normal → fator > 1 → espera maior
    v_factor := v_ref_checkouts / p_checkout_count::numeric;

    -- Limita o fator entre 0.4 e 3.0 para evitar extremos absurdos
    -- (ex: 50 caixas não torna a espera zero; 1 caixa não triplica o normal)
    v_factor := GREATEST(0.4, LEAST(3.0, v_factor));

  END IF;

  -- Aplica fator e arredonda para inteiro
  v_final_minutes := GREATEST(2, LEAST(60, ROUND(v_base_minutes * v_factor)));

  RETURN v_final_minutes || ' min';
END;
$$;


-- ─── 3. Atualizar run_location_snapshot() para passar checkout_count ─────────

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
           slug, vertical, location_context, checkout_count
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
    v_wait  := crowd_score_to_wait_time(
                 v_score,
                 v_location.checkout_count,   -- NULL → sem ajuste
                 v_location.size
               );
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


-- ─── Referência: como preencher checkout_count ───────────────────────────────
--
-- Preencha com o número TÍPICO de caixas abertos no horário de pico.
-- Não o número total de caixas instalados, mas os que ficam ativos no rush.
--
-- Exemplos reais:
--
--   Assaí / Atacadão (extra_large):
--     Referência = 18. Se abre ~10 caixas no pico → checkout_count = 10
--     Fator = 18/10 = 1.8 → wait_time × 1.8 (fila bem mais longa)
--
--   Supermercado grande (large):
--     Referência = 10. Se abre ~12 caixas no pico → checkout_count = 12
--     Fator = 10/12 = 0.83 → wait_time × 0.83 (flui um pouco melhor)
--
--   Mercadinho de bairro (small):
--     Referência = 2. Se tem 1 único caixa → checkout_count = 1
--     Fator = 2/1 = 2.0 → wait_time dobra (fila sensível a qualquer fluxo)
--
-- Para atualizar via SQL Editor:
--   UPDATE locations SET checkout_count = 10 WHERE name ILIKE '%assaí%';
--   UPDATE locations SET checkout_count = 3  WHERE size = 'small';
--
-- ─── Verificação ─────────────────────────────────────────────────────────────
--
-- Comparar wait_time com e sem checkout_count para crowd_score = 75:
--
--   SELECT
--     crowd_score_to_wait_time(75)           AS sem_info,      -- padrão
--     crowd_score_to_wait_time(75, 1, 'small')    AS small_1cx,    -- 2x mais
--     crowd_score_to_wait_time(75, 5, 'small')    AS small_5cx,    -- 0.4x (cap)
--     crowd_score_to_wait_time(75, 10, 'large')   AS large_10cx,   -- igual ref
--     crowd_score_to_wait_time(75, 4, 'large')    AS large_4cx,    -- 2.5x (cap 3x)
--     crowd_score_to_wait_time(75, 18, 'extra_large') AS assai_18cx; -- igual ref
