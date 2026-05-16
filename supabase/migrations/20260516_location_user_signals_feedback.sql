-- =============================================================================
-- GoWait — Feedback real do usuário sobre fluxo do local
-- Migration: location_user_signals_feedback
--
-- Adiciona suporte a event_type = 'feedback' com avaliação real
-- do fluxo percebido pelo usuário após visita ao local.
--
-- Valores de feedback_value: 'vazio', 'normal', 'cheio'
-- Esses dados são a fonte de verdade para calibrar crowd_score.
-- =============================================================================

-- 1. Adicionar coluna feedback_value (nullable — só preenchida em event feedback)
ALTER TABLE location_user_signals
  ADD COLUMN IF NOT EXISTS feedback_value text
  CHECK (feedback_value IN ('vazio', 'normal', 'cheio'));

-- 2. Adicionar 'feedback' como event_type válido
--    Recria o CHECK sem precisar dropar a coluna
ALTER TABLE location_user_signals
  DROP CONSTRAINT IF EXISTS location_user_signals_event_type_check;

ALTER TABLE location_user_signals
  ADD CONSTRAINT location_user_signals_event_type_check
  CHECK (event_type IN ('view', 'search', 'click', 'navigate', 'dismiss', 'return', 'feedback'));

-- 3. Índice para facilitar análise de feedback por local + horário
CREATE INDEX IF NOT EXISTS idx_lus_feedback
  ON location_user_signals (location_id, feedback_value, hour_of_day)
  WHERE event_type = 'feedback';

-- 4. View: feedback agregado por local + hora do dia
--    Permite comparar percepção real vs. crowd_score heurístico
CREATE OR REPLACE VIEW location_feedback_summary AS
SELECT
  lus.location_id,
  lus.hour_of_day,
  lus.day_of_week,
  COUNT(*)                                                        AS total_feedbacks,
  COUNT(*) FILTER (WHERE lus.feedback_value = 'vazio')           AS count_vazio,
  COUNT(*) FILTER (WHERE lus.feedback_value = 'normal')          AS count_normal,
  COUNT(*) FILTER (WHERE lus.feedback_value = 'cheio')           AS count_cheio,
  -- Score médio percebido pelo usuário: vazio=15, normal=50, cheio=85
  ROUND(AVG(
    CASE lus.feedback_value
      WHEN 'vazio'  THEN 15
      WHEN 'normal' THEN 50
      WHEN 'cheio'  THEN 85
    END
  ), 1)                                                           AS avg_perceived_score,
  -- Score heurístico médio no momento do feedback (para comparar divergência)
  ROUND(AVG(lus.score_at_event), 1)                              AS avg_heuristic_score
FROM location_user_signals lus
WHERE lus.event_type = 'feedback'
GROUP BY lus.location_id, lus.hour_of_day, lus.day_of_week;

-- Exemplo de query para detectar divergência entre heurística e percepção real:
--
--   SELECT location_id, hour_of_day,
--          avg_heuristic_score,
--          avg_perceived_score,
--          (avg_perceived_score - avg_heuristic_score) AS delta
--   FROM location_feedback_summary
--   WHERE ABS(avg_perceived_score - avg_heuristic_score) > 15
--   ORDER BY ABS(avg_perceived_score - avg_heuristic_score) DESC;
