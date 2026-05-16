import { WEIGHTS } from "./constants";
import { scoreToFlow, scoreToWaitTime, scoresToTrend } from "./converters";
import type { Market, SnapshotInput, SnapshotResult } from "./types";

// ─── Helpers internos ─────────────────────────────────────────────────────────

function getTimeBonus(hour: number): number {
  for (const { hours, bonus } of WEIGHTS.timeOfDay) {
    if (hours.includes(hour)) return bonus;
  }
  return 0; // madrugada
}

// ─── Engine principal ─────────────────────────────────────────────────────────

/**
 * Calcula o crowd_score (0–100) de um mercado para um dado momento.
 *
 * Extensível: adicionar novos modificadores aqui sem quebrar nada.
 * Todos os pesos centralizados em constants.ts.
 */
export function calculateCrowdScore(market: Market, now: Date, isHoliday = false): number {
  const hour       = now.getHours();
  const dayOfWeek  = now.getDay();        // 0 = domingo, 6 = sábado
  const dayOfMonth = now.getDate();
  const isWeekend  = dayOfWeek === 0 || dayOfWeek === 6;

  let score = WEIGHTS.base;

  // Fator estrutural do mercado (0–100, desvio em relação ao neutro 50)
  if (market.base_crowd_factor != null) {
    score += (market.base_crowd_factor - 50) * 0.3;
  }

  score += getTimeBonus(hour);

  if (isWeekend)             score += WEIGHTS.weekend;
  if (isHoliday)             score += WEIGHTS.holiday;
  if (dayOfMonth <= 5)       score += WEIGHTS.beginningOfMonth;

  const typeWeight = WEIGHTS.marketType[market.market_type];
  if (typeWeight) {
    score += isWeekend ? typeWeight.weekend : typeWeight.weekday;
  }

  score += WEIGHTS.priceLevel[market.price_level] ?? 0;
  score += WEIGHTS.size[market.size] ?? 0;

  // TODO: weather modifier → ex.: chuva +10 (pessoas evitam sair)
  // TODO: event modifier → shows/jogos perto do mercado

  return Math.min(100, Math.max(0, Math.round(score)));
}

// ─── Snapshot completo ────────────────────────────────────────────────────────

/**
 * Gera um SnapshotResult completo pronto para inserção em market_metrics
 * e atualização em markets.
 */
export function buildSnapshot(input: SnapshotInput): SnapshotResult {
  const {
    market,
    now = new Date(),
    isHoliday = false,
    weather = null,
    recentScores = [],
  } = input;

  const dayOfWeek  = now.getDay();
  const isWeekend  = dayOfWeek === 0 || dayOfWeek === 6;
  const crowd_score = calculateCrowdScore(market, now, isHoliday);
  const flow        = scoreToFlow(crowd_score);
  const wait_time   = scoreToWaitTime(crowd_score);
  const trend       = scoresToTrend(recentScores);

  return {
    market_id:   market.id,
    crowd_score,
    flow,
    wait_time,
    trend,
    is_holiday:  isHoliday,
    is_weekend:  isWeekend,
    day_of_week: dayOfWeek,
    hour_of_day: now.getHours(),
    weather:     weather ?? null,
  };
}
