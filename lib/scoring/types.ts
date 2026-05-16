export type MarketSize = "small" | "medium" | "large" | "extra_large";
export type MarketType =
  | "atacado"
  | "supermercado"
  | "mercado"
  | "premium"
  | "convenience"
  | "discount";
export type PriceLevel = "low" | "medium" | "high" | "premium";
export type Flow = "baixo" | "médio" | "alto";
export type Trend = "subindo" | "caindo" | "estável";

export interface Market {
  id: string;
  name: string;
  size: MarketSize;
  market_type: MarketType;
  price_level: PriceLevel;
  /** 0–100: fator base de lotação estrutural do mercado */
  base_crowd_factor: number;
}

export interface SnapshotInput {
  market: Market;
  /** Default: new Date() */
  now?: Date;
  isHoliday?: boolean;
  /** Prepared for future integrations (OpenWeatherMap, etc.) */
  weather?: string | null;
  /** Últimos N crowd_scores históricos, do mais antigo ao mais recente */
  recentScores?: number[];
}

export interface SnapshotResult {
  market_id: string;
  crowd_score: number;
  flow: Flow;
  wait_time: string;
  trend: Trend;
  is_holiday: boolean;
  is_weekend: boolean;
  day_of_week: number;
  hour_of_day: number;
  weather: string | null;
}
