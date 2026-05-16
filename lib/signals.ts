import { supabase } from "./supabase";

// ─── Tipos ────────────────────────────────────────────────────────────────────

/**
 * Tipos de evento capturados no app.
 *
 * Hierarquia de intenção (baixo → alto):
 *   dismiss(10) < search(20) < view(30) < click(60) < return(75) < navigate(90)
 */
export type SignalEvent =
  | "view"
  | "search"
  | "click"
  | "navigate"
  | "dismiss"
  | "return"
  | "feedback";

export type SignalSource = "nearby" | "search" | "map" | "recommendation";

export type FeedbackValue = "vazio" | "normal" | "cheio";

// ─── Constantes ───────────────────────────────────────────────────────────────

const INTENT_SCORE: Record<SignalEvent, number> = {
  dismiss:  10,
  search:   20,
  view:     30,
  click:    60,
  return:   75,
  navigate: 90,
  feedback: 95, // feedback prova que o usuário foi — intenção máxima
};

// ─── Interface ────────────────────────────────────────────────────────────────

interface SignalPayload {
  location_id:         string;
  event_type:          SignalEvent;
  source:              SignalSource;
  flow_at_event?:      string | null;
  score_at_event?:     number | null;
  dwell_time_seconds?: number | null;
  feedback_value?:     FeedbackValue | null;
}

// ─── Helper principal ─────────────────────────────────────────────────────────

/**
 * Registra um sinal de comportamento do usuário em `location_user_signals`.
 *
 * Fire-and-forget: nunca lança erro nem bloqueia a UI.
 * Falhas de rede são silenciosas intencionalmente — sinais são melhor-esforço.
 */
export function trackSignal(payload: SignalPayload): void {
  const now = new Date();
  const dow = now.getDay();

  supabase
    .from("location_user_signals")
    .insert({
      location_id:        payload.location_id,
      event_type:         payload.event_type,
      intent_score:       INTENT_SCORE[payload.event_type],
      dwell_time_seconds: payload.dwell_time_seconds ?? null,
      source:             payload.source,
      flow_at_event:      payload.flow_at_event    ?? null,
      score_at_event:     payload.score_at_event   ?? null,
      feedback_value:     payload.feedback_value   ?? null,
      hour_of_day:        now.getHours(),
      day_of_week:        dow,
      is_weekend:         dow === 0 || dow === 6,
      is_holiday:         false,
    })
    .then();
}

/**
 * Atalho para registrar avaliação pós-visita.
 * "Eu fui ao local — estava assim."
 */
export function trackFeedback(
  location_id:    string,
  feedback_value: FeedbackValue,
  flow_at_event:  string | null,
  score_at_event: number | null,
): void {
  trackSignal({
    location_id,
    event_type:     "feedback",
    source:         "nearby",
    flow_at_event,
    score_at_event,
    feedback_value,
  });
}
