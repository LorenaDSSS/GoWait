// @ts-nocheck — arquivo Deno (Supabase Edge Function), não Node.js
/**
 * Supabase Edge Function: location-snapshot
 *
 * Responsabilidade:
 *   1. Ler todos os locais de `locations`
 *   2. Calcular crowd_score heurístico para o momento atual
 *   3. Inserir snapshot em `location_metrics`
 *   4. Atualizar flow / wait_time / trend em `locations`
 *
 * Deploy:
 *   supabase functions deploy location-snapshot
 *
 * Scheduling (Supabase Dashboard > Database > Cron Jobs):
 *   Cron: "a cada 15 minutos"  ->  POST /functions/v1/location-snapshot
 *
 * Env vars necessários (já injetados pelo Supabase runtime):
 *   SUPABASE_URL
 *   SUPABASE_SERVICE_ROLE_KEY
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ─── Types ────────────────────────────────────────────────────────────────────

type Flow  = "baixo" | "médio" | "alto";
type Trend = "subindo" | "caindo" | "estável";

interface Market {
  id: string;
  size: string;
  segment: string;       // antes: market_type
  vertical: string;      // categoria de produto (mercado, farmácia, etc.)
  price_level: string;
  base_crowd_factor: number;
  slug: string;
}

// ─── Pesos (espelho de lib/scoring/constants.ts) ──────────────────────────────
// Mantidos inline para que a Edge Function seja auto-contida (sem imports locais).

const WEIGHTS = {
  base: 30,
  weekend: 20,
  holiday: 25,
  beginningOfMonth: 10,
  timeOfDay: [
    { hours: [7, 8],        bonus: 8  },
    { hours: [9, 10],       bonus: 12 },
    { hours: [11, 12, 13],  bonus: 18 },
    { hours: [14, 15, 16],  bonus: 8  },
    { hours: [17, 18, 19],  bonus: 25 },
    { hours: [20, 21],      bonus: 12 },
    { hours: [22, 23],      bonus: 5  },
  ],
  marketType: {
    atacado:      { weekday: 8,   weekend: 20  },
    supermercado: { weekday: 0,   weekend: 5   },
    mercado:      { weekday: 0,   weekend: 0   },
    premium:      { weekday: -10, weekend: -5  },
    convenience:  { weekday: -5,  weekend: -5  },
    discount:     { weekday: 12,  weekend: 15  },
  } as Record<string, { weekday: number; weekend: number }>,
  priceLevel: { low: 15, medium: 0, high: -10, premium: -15 } as Record<string, number>,
  size: { small: 12, medium: 0, large: -8, extra_large: -15 } as Record<string, number>,
};

const FLOW_THRESHOLDS = { baixo: 35, medio: 70 };
const WAIT_RANGES: Record<Flow, [number, number]> = {
  baixo: [5, 10],
  médio: [12, 20],
  alto:  [25, 40],
};
const TREND_DELTA = 8;

// ─── Engine ───────────────────────────────────────────────────────────────────

function getTimeBonus(hour: number): number {
  for (const { hours, bonus } of WEIGHTS.timeOfDay) {
    if (hours.includes(hour)) return bonus;
  }
  return 0;
}

function calculateCrowdScore(market: Market, now: Date, isHoliday: boolean): number {
  const hour       = now.getHours();
  const dow        = now.getDay();
  const dom        = now.getDate();
  const isWeekend  = dow === 0 || dow === 6;

  let score = WEIGHTS.base;
  if (market.base_crowd_factor != null) score += (market.base_crowd_factor - 50) * 0.3;
  score += getTimeBonus(hour);
  if (isWeekend)        score += WEIGHTS.weekend;
  if (isHoliday)        score += WEIGHTS.holiday;
  if (dom <= 5)         score += WEIGHTS.beginningOfMonth;

  const tw = WEIGHTS.marketType[market.segment];
  if (tw) score += isWeekend ? tw.weekend : tw.weekday;

  score += WEIGHTS.priceLevel[market.price_level] ?? 0;
  score += WEIGHTS.size[market.size] ?? 0;

  return Math.min(100, Math.max(0, Math.round(score)));
}

function scoreToFlow(score: number): Flow {
  if (score <= FLOW_THRESHOLDS.baixo) return "baixo";
  if (score <= FLOW_THRESHOLDS.medio) return "médio";
  return "alto";
}

function scoreToWaitTime(score: number): string {
  const flow = scoreToFlow(score);
  const ranges: Record<Flow, [number, number]> = {
    baixo: [0, 35], médio: [36, 70], alto: [71, 100],
  };
  const [sMin, sMax] = ranges[flow];
  const [wMin, wMax] = WAIT_RANGES[flow];
  const rel = sMax > sMin ? (score - sMin) / (sMax - sMin) : 0;
  return `${Math.round(wMin + rel * (wMax - wMin))} min`;
}

function computeTrend(recentScores: number[]): Trend {
  if (recentScores.length < 4) return "estável";
  const half    = Math.floor(recentScores.length / 2);
  const oldAvg  = recentScores.slice(0, half).reduce((a, b) => a + b, 0) / half;
  const newAvg  = recentScores.slice(-half).reduce((a, b) => a + b, 0) / half;
  const delta   = newAvg - oldAvg;
  if (delta >  TREND_DELTA) return "subindo";
  if (delta < -TREND_DELTA) return "caindo";
  return "estável";
}

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async () => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const now        = new Date();
  const dow        = now.getDay();
  const isWeekend  = dow === 0 || dow === 6;
  const isHoliday  = false; // TODO: integrar API de feriados

  try {
    // 1. Carregar locais
    const { data: locations, error: mErr } = await supabase
      .from("locations")
      .select("id, size, segment, vertical, price_level, base_crowd_factor, slug");
    if (mErr) throw mErr;

    const inserts  = [];
    const updates  = [];

    for (const location of locations as Market[]) {
      // 2. Buscar histórico recente para tendência
      const { data: recent } = await supabase
        .from("location_metrics")
        .select("crowd_score")
        .eq("location_id", location.id)
        .order("created_at", { ascending: false })
        .limit(6);

      const recentScores = ((recent ?? []) as { crowd_score: number }[])
        .map((r) => r.crowd_score)
        .reverse();

      // 3. Calcular
      const crowd_score = calculateCrowdScore(location, now, isHoliday);
      const flow        = scoreToFlow(crowd_score);
      const wait_time   = scoreToWaitTime(crowd_score);
      const trend       = computeTrend(recentScores);

      inserts.push({
        location_id: location.id,
        slug:        location.slug,
        vertical:    location.vertical,
        crowd_score,
        flow,
        wait_time,
        trend,
        is_holiday:  isHoliday,
        is_weekend:  isWeekend,
        day_of_week: dow,
        hour_of_day: now.getHours(),
        weather:     null,
      });

      updates.push({ id: location.id, flow, wait_time, trend });
    }

    // 4. Inserir snapshots em lote
    const { error: insErr } = await supabase.from("location_metrics").insert(inserts);
    if (insErr) throw insErr;

    // 5. Atualizar estado atual em locations
    for (const u of updates) {
      await supabase
        .from("locations")
        .update({ flow: u.flow, wait_time: u.wait_time, trend: u.trend })
        .eq("id", u.id);
    }

    return new Response(
      JSON.stringify({ success: true, processed: locations.length, at: now.toISOString() }),
      { headers: { "Content-Type": "application/json" }, status: 200 },
    );
  } catch (err) {
    console.error("[market-snapshot]", err);
    return new Response(
      JSON.stringify({ success: false, error: String(err) }),
      { headers: { "Content-Type": "application/json" }, status: 500 },
    );
  }
});
