-- =============================================================================
-- GoWait — Atualiza limiares de fluxo
-- Migration: flow_thresholds
--
-- Novo mapeamento crowd_score → flow:
--   0–40  → baixo
--   41–70 → médio
--   71–100 → alto
--
-- Anterior: baixo ≤ 35, médio 36–70, alto > 70
-- =============================================================================


-- ─── 1. crowd_score_to_flow ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION crowd_score_to_flow(p_score int)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_score <= 55 THEN 'baixo'
    WHEN p_score <= 75 THEN 'médio'
    ELSE 'alto'
  END;
$$;


-- ─── 2. crowd_score_to_wait_time ─────────────────────────────────────────────
--
-- Faixas de espera inalteradas (5–10, 12–20, 25–40 min).
-- Apenas os limites de score foram ajustados.

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
  v_base_minutes := CASE
    WHEN p_score <= 55 THEN  5 + ROUND(( p_score::numeric          / 55)  *  5)  -- 5–10 min
    WHEN p_score <= 75 THEN 12 + ROUND(((p_score - 56)::numeric    / 19)  *  8)  -- 12–20 min
    ELSE                     25 + ROUND(((p_score - 76)::numeric   / 24)  * 15)  -- 25–40 min
  END;

  IF p_checkout_count IS NOT NULL AND p_checkout_count > 0 THEN
    v_ref_checkouts := CASE p_size
      WHEN 'small'       THEN  2
      WHEN 'large'       THEN 10
      WHEN 'extra_large' THEN 18
      ELSE                    5
    END;
    v_factor := v_ref_checkouts / p_checkout_count::numeric;
    v_factor := GREATEST(0.4, LEAST(3.0, v_factor));
  END IF;

  v_final_minutes := GREATEST(2, LEAST(60, ROUND(v_base_minutes * v_factor)));
  RETURN v_final_minutes || ' min';
END;
$$;
