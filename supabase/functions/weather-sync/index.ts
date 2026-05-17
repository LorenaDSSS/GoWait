// @ts-nocheck — arquivo Deno (Supabase Edge Function), não Node.js
/**
 * Supabase Edge Function: weather-sync
 *
 * Responsabilidade:
 *   1. Buscar condição climática atual via OpenWeatherMap (free tier)
 *   2. Classificar em: rain | cold | hot | clear
 *   3. Upsert em weather_cache (uma linha por cidade)
 *
 * Deploy:
 *   supabase functions deploy weather-sync
 *
 * Secret necessário (Dashboard > Edge Functions > Secrets):
 *   OPENWEATHER_API_KEY  — chave gratuita em https://openweathermap.org/api
 *
 * Scheduling (Dashboard > Database > Cron Jobs):
 *   Cron: a cada 30 minutos → POST /functions/v1/weather-sync
 *
 * Classificação de condição:
 *   rain  → weather[0].main IN (Rain, Drizzle, Thunderstorm) → +15 pts no score
 *   cold  → temp < 18°C (e não chove)                       → +8 pts no score
 *   hot   → temp > 30°C (e não chove)                       → +8 pts no score
 *   clear → qualquer outro caso                              → sem impacto
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Cidades a monitorar.
// Coordenadas são mais precisas que nome de cidade para bairros.
// Campo Grande / Rio de Janeiro — cobre as 3 lojas cadastradas.
const CITIES = [
  { key: "campo_grande_rj", lat: -22.9054, lon: -43.5636 },
];

// Temperatura limite para classificação de frio/calor
const COLD_THRESHOLD = 18; // °C
const HOT_THRESHOLD  = 30; // °C

// Condições OWM que mapeiam para "rain"
const RAIN_MAINS = new Set(["Rain", "Drizzle", "Thunderstorm"]);

function classifyCondition(weatherMain: string, tempC: number): string {
  if (RAIN_MAINS.has(weatherMain))           return "rain";
  if (tempC < COLD_THRESHOLD)                return "cold";
  if (tempC > HOT_THRESHOLD)                 return "hot";
  return "clear";
}

Deno.serve(async () => {
  const apiKey = Deno.env.get("OPENWEATHER_API_KEY");
  if (!apiKey) {
    return new Response(
      JSON.stringify({ error: "OPENWEATHER_API_KEY não configurado" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const results = [];

  for (const city of CITIES) {
    try {
      const url =
        `https://api.openweathermap.org/data/2.5/weather` +
        `?lat=${city.lat}&lon=${city.lon}&appid=${apiKey}&units=metric`;

      const res  = await fetch(url);
      if (!res.ok) {
        results.push({ city: city.key, error: `OWM status ${res.status}` });
        continue;
      }

      const data     = await res.json();
      const rawMain  = data.weather?.[0]?.main ?? "Clear";
      const tempC    = data.main?.temp          ?? 25;
      const condition = classifyCondition(rawMain, tempC);

      const { error } = await supabase.from("weather_cache").upsert(
        { city: city.key, condition, temp_c: tempC, raw_main: rawMain, updated_at: new Date().toISOString() },
        { onConflict: "city" },
      );

      if (error) {
        results.push({ city: city.key, error: error.message });
      } else {
        results.push({ city: city.key, condition, temp_c: tempC, raw_main: rawMain });
      }
    } catch (err) {
      results.push({ city: city.key, error: String(err) });
    }
  }

  return new Response(JSON.stringify({ ok: true, results }), {
    headers: { "Content-Type": "application/json" },
  });
});
