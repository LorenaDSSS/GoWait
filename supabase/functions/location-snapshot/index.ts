// @ts-nocheck — arquivo Deno (Supabase Edge Function), não Node.js
/**
 * Supabase Edge Function: location-snapshot
 *
 * Responsabilidade:
 *   1. Ler todos os locais de `locations`
 *   2. Ler condição climática atual de `weather_cache` (máx 2h)
 *   3. Calcular crowd_score heurístico para o momento atual
 *   4. Inserir snapshot em `location_metrics`
 *   5. Atualizar flow / wait_time / trend / crowd_score / snapshot_at em `locations`
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
  id:                 string;
  size:               string;
  segment:            string;
  vertical:           string;
  price_level:        string;
  base_crowd_factor:  number;
  location_context:   string;
  checkout_count:     number | null;
  slug:               string;
  city:               string | null;
}

// Extrai o município de "Bairro, Município - UF" → "Município"
// Ex: "Catete, Rio de Janeiro - RJ" → "Rio de Janeiro"
// Ex: "Rio de Janeiro" → "Rio de Janeiro" (fallback sem vírgula)
function extractMunicipio(city: string | null | undefined): string | null {
  if (!city) return null;
  const comma = city.indexOf(",");
  const dash  = city.lastIndexOf(" - ");
  const start = comma === -1 ? 0 : comma + 1;
  const end   = dash  === -1 ? city.length : dash;
  return city.slice(start, end).trim() || null;
}

interface IntelEntry {
  intelligence_score: number;
  confidence_level:   "low" | "medium" | "high";
}

// ─── Pesos ────────────────────────────────────────────────────────────────────

const FLOW_THRESHOLDS = { baixo: 55, medio: 75 };
const WAIT_RANGES: Record<Flow, [number, number]> = {
  baixo: [5, 10],
  médio: [12, 20],
  alto:  [25, 40],
};
const COLD_THRESHOLD = 18;
const HOT_THRESHOLD  = 30;

// ─── Engine ───────────────────────────────────────────────────────────────────

function getTimeBonus(hour: number, context: string): number {
  switch (context) {
    case "mall":
      if (hour >= 7  && hour <= 9)  return 2;
      if (hour >= 10 && hour <= 11) return 8;
      if (hour >= 12 && hour <= 13) return 15;
      if (hour >= 14 && hour <= 17) return 22;
      if (hour >= 18 && hour <= 20) return 18;
      if (hour === 21)              return 10;
      if (hour >= 22)               return 4;
      return 0;
    case "comercial_street":
      if (hour >= 7  && hour <= 8)  return 12;
      if (hour >= 9  && hour <= 10) return 15;
      if (hour >= 11 && hour <= 13) return 25;
      if (hour >= 14 && hour <= 16) return 10;
      if (hour >= 17 && hour <= 18) return 20;
      if (hour >= 19 && hour <= 20) return 8;
      if (hour >= 21)               return 3;
      return 0;
    case "transit_hub":
      if (hour >= 5  && hour <= 6)  return 15;
      if (hour >= 7  && hour <= 8)  return 22;
      if (hour >= 9  && hour <= 10) return 10;
      if (hour >= 11 && hour <= 13) return 12;
      if (hour >= 14 && hour <= 16) return 8;
      if (hour >= 17 && hour <= 19) return 22;
      if (hour === 20)              return 10;
      if (hour >= 21)               return 5;
      return 0;
    default: // standalone, residential
      if (hour >= 7  && hour <= 8)  return 8;
      if (hour >= 9  && hour <= 10) return 12;
      if (hour >= 11 && hour <= 13) return 18;
      if (hour >= 14 && hour <= 16) return 8;
      if (hour >= 17 && hour <= 19) return 25;
      if (hour >= 20 && hour <= 21) return 12;
      if (hour >= 22)               return 5;
      return 0;
  }
}

function getWeekendBonus(context: string): number {
  switch (context) {
    case "mall":             return 25;
    case "residential":      return 22;
    case "transit_hub":      return 8;
    case "comercial_street": return 10;
    default:                 return 20;
  }
}

function calculateCrowdScore(
  market: Market,
  now: Date,
  isHoliday: boolean,
  weather: string | null,
): number {
  const hour       = now.getHours();
  const dow        = now.getDay();
  const dom        = now.getDate();
  const isWeekend  = dow === 0 || dow === 6;
  const context    = market.location_context ?? "standalone";

  let score = 30;
  if (market.base_crowd_factor != null) score += (market.base_crowd_factor - 50) * 0.3;

  score += getTimeBonus(hour, context);

  if (isWeekend) score += getWeekendBonus(context);
  if (isHoliday) score += 25;

  // Efeito salário + quinzena (peso por segmento)
  // Dias 1–7: salário mensal (5º dia útil pode cair até dia 7)
  // Dias 13–16: quinzena/adiantamento
  if (dom <= 7 || (dom >= 13 && dom <= 16)) {
    const salaryBonus: Record<string, number> = {
      atacado: 18, discount: 15, supermercado: 12, convenience: 6, premium: 4,
    };
    score += salaryBonus[market.segment] ?? 10;
  }

  // Segmento
  const seg = market.segment;
  if (seg === "atacado")      score += isWeekend ? 20 : 8;
  else if (seg === "supermercado") score += isWeekend ? 5 : 0;
  else if (seg === "premium") score += isWeekend ? -5 : -10;
  else if (seg === "convenience") score -= 5;
  else if (seg === "discount") score += isWeekend ? 15 : 12;

  // Preço
  if      (market.price_level === "low")     score += 15;
  else if (market.price_level === "high")    score -= 10;
  else if (market.price_level === "premium") score -= 15;

  // Tamanho
  if      (market.size === "small")       score += 12;
  else if (market.size === "large")       score -= 8;
  else if (market.size === "extra_large") score -= 15;

  // Clima
  if      (weather === "rain") score += 15;
  else if (weather === "cold") score += 8;
  else if (weather === "hot")  score += 8;

  return Math.min(100, Math.max(0, Math.round(score)));
}

function predictNextScore(market: Market, now: Date, isHoliday: boolean): number {
  const nextHour = new Date(now.getTime() + 60 * 60 * 1000);
  // Tendência não inclui clima (delta horário é independente de condição atual)
  return calculateCrowdScore(market, nextHour, isHoliday, null);
}

function scoreToFlow(score: number): Flow {
  if (score <= FLOW_THRESHOLDS.baixo) return "baixo";
  if (score <= FLOW_THRESHOLDS.medio) return "médio";
  return "alto";
}

function scoreToWaitTime(score: number, checkoutCount: number | null, size: string): string {
  const flow = scoreToFlow(score);
  const ranges: Record<Flow, [number, number]> = {
    baixo: [0, 55], médio: [56, 75], alto: [76, 100],
  };
  const [sMin, sMax] = ranges[flow];
  const [wMin, wMax] = WAIT_RANGES[flow];
  const rel = sMax > sMin ? (score - sMin) / (sMax - sMin) : 0;
  let base = Math.round(wMin + rel * (wMax - wMin));

  // Ajuste por checkout_count
  if (checkoutCount != null && checkoutCount > 0) {
    const ref: Record<string, number> = { small: 2, medium: 5, large: 10, extra_large: 18 };
    const factor = Math.min(3.0, Math.max(0.4, (ref[size] ?? 5) / checkoutCount));
    base = Math.max(2, Math.min(60, Math.round(base * factor)));
  }

  return `${base} min`;
}

function computeTrend(current: number, next: number): Trend {
  const delta = next - current;
  if (delta >  5) return "subindo";
  if (delta < -5) return "caindo";
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
    // 1. Carregar mapa de clima por município (máx 2h)
    const twoHoursAgo = new Date(now.getTime() - 2 * 60 * 60 * 1000).toISOString();
    const { data: weatherRows } = await supabase
      .from("weather_cache")
      .select("city, condition")
      .gte("updated_at", twoHoursAgo);
    // Map: "Rio de Janeiro" → "rain" | "cold" | "hot" | "clear"
    const weatherMap = new Map<string, string>();
    for (const row of (weatherRows ?? [])) {
      if (row.city) weatherMap.set(row.city, row.condition);
    }

    // 2. Carregar locais
    const { data: locations, error: mErr } = await supabase
      .from("locations")
      .select("id, size, segment, vertical, price_level, base_crowd_factor, location_context, checkout_count, slug, city");
    if (mErr) throw mErr;

    // 3. Carregar intelligence em batch (uma query para todos os locais)
    const { data: intelRows } = await supabase
      .from("location_intelligence")
      .select("location_id, intelligence_score, confidence_level");
    const intelMap = new Map<string, IntelEntry>();
    for (const row of (intelRows ?? [])) {
      intelMap.set(row.location_id, {
        intelligence_score: row.intelligence_score,
        confidence_level:   row.confidence_level,
      });
    }

    const inserts = [];
    const updates = [];

    for (const location of locations as Market[]) {
      // Clima do município do local (fallback null = sem efeito no score)
      const municipio = extractMunicipio(location.city);
      const weather   = municipio ? (weatherMap.get(municipio) ?? null) : null;

      // Score heurístico puro — vai para location_metrics (input da IA)
      const heuristic_score = calculateCrowdScore(location, now, isHoliday, weather);
      const score_next      = predictNextScore(location, now, isHoliday);

      // Blend baseado em confidence_level
      const intel        = intelMap.get(location.id);
      let effective_score = heuristic_score;
      if (intel && intel.intelligence_score != null) {
        if (intel.confidence_level === "medium") {
          effective_score = Math.max(0, Math.min(100, Math.round(0.75 * heuristic_score + 0.25 * intel.intelligence_score)));
        } else if (intel.confidence_level === "high") {
          effective_score = Math.max(0, Math.min(100, Math.round(0.50 * heuristic_score + 0.50 * intel.intelligence_score)));
        }
        // confidence = 'low' → 100% heurístico (effective_score já é heuristic_score)
      }

      // flow/wait/trend derivados do score EFETIVO (o que o usuário vai ver)
      const flow      = scoreToFlow(effective_score);
      const wait_time = scoreToWaitTime(effective_score, location.checkout_count, location.size);
      const trend     = computeTrend(heuristic_score, score_next);

      inserts.push({
        location_id: location.id,
        slug:        location.slug,
        vertical:    location.vertical,
        crowd_score: heuristic_score, // heurístico puro — não contaminado pelo blend
        flow,
        wait_time,
        trend,
        is_holiday:  isHoliday,
        is_weekend:  isWeekend,
        day_of_week: dow,
        hour_of_day: now.getHours(),
        weather,
      });

      updates.push({ id: location.id, flow, wait_time, trend, crowd_score: effective_score });
    }

    // 3. Inserir snapshots em lote
    const { error: insErr } = await supabase.from("location_metrics").insert(inserts);
    if (insErr) throw insErr;

    // 4. Atualizar estado atual em locations
    for (const u of updates) {
      await supabase
        .from("locations")
        .update({
          flow:        u.flow,
          wait_time:   u.wait_time,
          trend:       u.trend,
          crowd_score: u.crowd_score,
          snapshot_at: now.toISOString(),
        })
        .eq("id", u.id);
    }

    return new Response(
      JSON.stringify({ success: true, processed: locations.length, weather, at: now.toISOString() }),
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
