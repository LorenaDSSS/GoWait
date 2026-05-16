import {
    FLOW_SCORE_RANGES,
    TREND_DELTA_THRESHOLD,
    TREND_WINDOW,
    WAIT_RANGES,
} from "./constants";
import type { Flow, Trend } from "./types";

// ─── crowd_score → flow ───────────────────────────────────────────────────────

export function scoreToFlow(score: number): Flow {
  if (score <= FLOW_SCORE_RANGES.baixo[1]) return "baixo";
  if (score <= FLOW_SCORE_RANGES.médio[1]) return "médio";
  return "alto";
}

// ─── crowd_score → wait_time ─────────────────────────────────────────────────

/**
 * Mapeia o score para um tempo de espera proporcional dentro da faixa do fluxo.
 * Resultado determinístico (sem random): score 35 = máximo de "baixo" = 10 min.
 */
export function scoreToWaitTime(score: number): string {
  const flow = scoreToFlow(score);
  const [scoreMin, scoreMax] = FLOW_SCORE_RANGES[flow];
  const [waitMin, waitMax] = WAIT_RANGES[flow];
  const scoreRange = scoreMax - scoreMin;
  const relative = scoreRange > 0 ? (score - scoreMin) / scoreRange : 0;
  const minutes = Math.round(waitMin + relative * (waitMax - waitMin));
  return `${minutes} min`;
}

// ─── histórico → trend ────────────────────────────────────────────────────────

/**
 * Recebe os últimos `TREND_WINDOW` scores (do mais antigo ao mais recente)
 * e retorna a tendência comparando a média da primeira metade com a segunda.
 */
export function scoresToTrend(recentScores: number[]): Trend {
  if (recentScores.length < 4) return "estável";

  const scores = recentScores.slice(-TREND_WINDOW);
  const half = Math.floor(scores.length / 2);

  const oldAvg = scores.slice(0, half).reduce((a, b) => a + b, 0) / half;
  const newAvg = scores.slice(-half).reduce((a, b) => a + b, 0) / half;
  const delta = newAvg - oldAvg;

  if (delta > TREND_DELTA_THRESHOLD) return "subindo";
  if (delta < -TREND_DELTA_THRESHOLD) return "caindo";
  return "estável";
}
