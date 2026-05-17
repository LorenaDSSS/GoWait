#!/usr/bin/env node
/**
 * GoWait — Importador de locais via OpenStreetMap (Overpass API)
 *
 * O que faz:
 *   1. Consulta a Overpass API (gratuita, sem API key) buscando
 *      supermercados, atacados e lojas de conveniência no Rio de Janeiro
 *   2. Classifica cada local automaticamente por segment/size/price_level
 *      com base no nome da rede
 *   3. Gera um arquivo SQL com INSERTs prontos para colar no SQL Editor
 *
 * Como usar:
 *   node scripts/import-locations-rj.js
 *
 *   Isso gera: scripts/output/locations_rj.sql
 *   Cole o conteúdo no SQL Editor do Supabase e execute.
 *
 * Requisitos:
 *   Node 18+ (fetch nativo disponível)
 */

import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUTPUT_DIR = join(__dirname, "output");

// ─── Cache de geocoding (Nominatim) ──────────────────────────────────────────

const GEOCODE_CACHE_PATH = join(OUTPUT_DIR, "nominatim_cache.json");
let geocodeCache = {};

function loadGeocodeCache() {
  if (existsSync(GEOCODE_CACHE_PATH)) {
    geocodeCache = JSON.parse(readFileSync(GEOCODE_CACHE_PATH, "utf8"));
  }
}

function saveGeocodeCache() {
  mkdirSync(OUTPUT_DIR, { recursive: true });
  writeFileSync(GEOCODE_CACHE_PATH, JSON.stringify(geocodeCache), "utf8");
}

// Arredonda para 4 casas (≈ 11m de precisão) — chave do cache
function geoKey(lat, lon) {
  return `${lat.toFixed(4)},${lon.toFixed(4)}`;
}

async function reverseGeocode(lat, lon) {
  const key = geoKey(lat, lon);
  if (geocodeCache[key] !== undefined) return geocodeCache[key];

  try {
    const url = `https://nominatim.openstreetmap.org/reverse?lat=${lat}&lon=${lon}&format=json&addressdetails=1`;
    const res = await fetch(url, {
      headers: { "User-Agent": "GoWait/1.0 (import script; contato: gowaitapp@gmail.com)" },
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const addr = data.address || {};

    const suburb       = addr.suburb || addr.neighbourhood || addr.city_district || addr.district || null;
    const municipality = addr.city || addr.town || addr.county || "Rio de Janeiro";

    geocodeCache[key] = { suburb, municipality };
  } catch {
    geocodeCache[key] = { suburb: null, municipality: "Rio de Janeiro" };
  }

  return geocodeCache[key];
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ─── Mapeamento de redes conhecidas → segment / size / price_level ────────────

const NETWORK_MAP = [
  // Atacado / Atacarejo
  { pattern: /assaí|assai/i,          segment: "atacado",      size: "extra_large", price_level: "low",    base: 60 },
  { pattern: /atacad[aã]o/i,          segment: "atacado",      size: "extra_large", price_level: "low",    base: 60 },
  { pattern: /maxxi/i,                segment: "atacado",      size: "extra_large", price_level: "low",    base: 58 },
  { pattern: /sam.?s club/i,          segment: "atacado",      size: "extra_large", price_level: "medium", base: 55 },

  // Discount / Popular
  { pattern: /guanabara/i,            segment: "discount",     size: "large",       price_level: "low",    base: 55 },
  { pattern: /prezunic/i,             segment: "discount",     size: "large",       price_level: "low",    base: 52 },
  { pattern: /mundial/i,              segment: "discount",     size: "large",       price_level: "low",    base: 52 },
  { pattern: /supermarket|supermix/i, segment: "discount",     size: "medium",      price_level: "low",    base: 48 },
  { pattern: /rede economia|redeconomia/i, segment: "discount", size: "medium",     price_level: "low",    base: 48 },
  { pattern: /super rede/i,           segment: "discount",     size: "medium",      price_level: "low",    base: 48 },
  { pattern: /rede super/i,           segment: "discount",     size: "medium",      price_level: "low",    base: 48 },
  { pattern: /vianense/i,             segment: "discount",     size: "medium",      price_level: "low",    base: 48 },
  { pattern: /costazul/i,             segment: "discount",     size: "medium",      price_level: "low",    base: 48 },

  // Supermercado padrão
  { pattern: /extra\b/i,              segment: "supermercado", size: "large",       price_level: "medium", base: 50 },
  { pattern: /carrefour/i,            segment: "supermercado", size: "large",       price_level: "medium", base: 50 },
  { pattern: /bistek|bfs/i,           segment: "supermercado", size: "medium",      price_level: "medium", base: 48 },
  { pattern: /super.?rio/i,           segment: "supermercado", size: "medium",      price_level: "medium", base: 48 },
  { pattern: /hortifrut/i,            segment: "supermercado", size: "small",       price_level: "medium", base: 45 },

  // Premium
  { pattern: /pão de açúcar|pao de acucar/i, segment: "premium", size: "large",    price_level: "high",   base: 42 },
  { pattern: /zona sul/i,             segment: "premium",      size: "medium",      price_level: "high",   base: 40 },
  { pattern: /natural da terra/i,     segment: "premium",      size: "medium",      price_level: "high",   base: 38 },
  { pattern: /empório|emporio/i,      segment: "premium",      size: "small",       price_level: "premium",base: 35 },

  // Conveniência
  { pattern: /oxxo/i,                 segment: "convenience",  size: "small",       price_level: "medium", base: 40 },
  { pattern: /am.?pm/i,               segment: "convenience",  size: "small",       price_level: "medium", base: 40 },
  { pattern: /minimercado|mini mercado/i, segment: "convenience", size: "small",    price_level: "medium", base: 42 },
];

const DEFAULT_PROFILE = { segment: "supermercado", size: "medium", price_level: "medium", base: 48 };

function classify(name) {
  if (!name) return DEFAULT_PROFILE;
  for (const rule of NETWORK_MAP) {
    if (rule.pattern.test(name)) {
      return { segment: rule.segment, size: rule.size, price_level: rule.price_level, base: rule.base };
    }
  }
  return DEFAULT_PROFILE;
}

// ─── Gera slug único a partir do nome + id OSM ───────────────────────────────

function slugify(name, osmId) {
  return (
    name
      .toLowerCase()
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "")
      .slice(0, 40) +
    "-" +
    osmId
  );
}

// ─── Inferir context a partir do bairro/endereço (heurística simples) ────────
// OSM raramente tem o tipo de contexto — deixamos "standalone" como padrão seguro.

function inferContext(tags, name = "") {
  // 1. Checar tags OSM de localização (shopping, terminal, etc.)
  const addr = [
    tags["addr:street"]   || "",
    tags["addr:suburb"]   || "",
    tags["addr:place"]    || "",
    tags["operator"]      || "",
    tags["loc_name"]      || "",
  ].join(" ").toLowerCase();
  const haystack = (addr + " " + name).toLowerCase();

  if (/shopping|center|centre|mall|galeria|plaza/i.test(haystack)) return "mall";
  if (/terminal|rodoviária|rodoviaria|\bmetrô\b|\bmetro\b|estação\b|estacao\b/i.test(haystack)) return "transit_hub";

  // 2. Inferência por segmento (classify() já foi chamado antes)
  // Convenience = geralmente em calçadão comercial ou posto de combustível
  const shopType = tags["shop"] || "";
  if (/^convenience$/i.test(shopType)) return "comercial_street";

  return "standalone";
}

// ─── Consulta Overpass API ────────────────────────────────────────────────────

const OVERPASS_ENDPOINTS = [
  "https://overpass.private.coffee/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://overpass-api.de/api/interpreter",
  "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
  "https://overpass.openstreetmap.ru/api/interpreter",
];

async function fetchMarkets() {
  // Cache local para evitar rate limit em re-execuções
  const cachePath = join(OUTPUT_DIR, "overpass_cache.json");
  const MAX_AGE_H = 24; // horas

  if (existsSync(cachePath)) {
    const ageMs = Date.now() - statSync(cachePath).mtimeMs;
    if (ageMs < MAX_AGE_H * 3600 * 1000) {
      console.log(`📦 Usando cache Overpass (${Math.round(ageMs / 60000)} min atrás)`);
      return JSON.parse(readFileSync(cachePath, "utf8"));
    }
  }

  // Bounding box do Rio de Janeiro município: S -23.08, W -43.80, N -22.74, E -43.09
  const query = `
    [out:json][timeout:60];
    (
      node["shop"="supermarket"](-23.08,-43.80,-22.74,-43.09);
      way["shop"="supermarket"](-23.08,-43.80,-22.74,-43.09);
      node["shop"="wholesale"](-23.08,-43.80,-22.74,-43.09);
      way["shop"="wholesale"](-23.08,-43.80,-22.74,-43.09);
      node["shop"="convenience"](-23.08,-43.80,-22.74,-43.09);
    );
    out center tags;
  `;

  for (const endpoint of OVERPASS_ENDPOINTS) {
    console.log(`🔍 Tentando: ${endpoint}`);
    try {
      const res = await fetch(endpoint, {
        method: "POST",
        body: "data=" + encodeURIComponent(query),
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        signal: AbortSignal.timeout(70000),
      });

      if (!res.ok) {
        console.log(`   ⚠️  HTTP ${res.status} — tentando próximo...`);
        continue;
      }

      const json = await res.json();
      console.log(`✅ Sucesso via ${endpoint}`);

      // Salva cache
      mkdirSync(OUTPUT_DIR, { recursive: true });
      writeFileSync(cachePath, JSON.stringify(json.elements), "utf8");
      console.log(`💾 Cache Overpass salvo`);

      return json.elements;
    } catch (err) {
      console.log(`   ⚠️  Erro (${err.message}) — tentando próximo...`);
    }
  }

  throw new Error(
    "Todos os servidores Overpass falharam.\n" +
    "Tente novamente em alguns minutos — pode ser instabilidade temporária.\n" +
    "Status em tempo real: https://overpass-api.de/api/status"
  );
}

// ─── Gera SQL ────────────────────────────────────────────────────────────────

async function generateSQL(elements) {
  const rows = [];
  const seen = new Set();

  // Coleta locais únicos antes de geocodar
  const pending = [];
  for (const el of elements) {
    const tags = el.tags || {};
    const name = tags.name || tags["name:pt"] || null;
    if (!name) continue;

    const lat = el.lat ?? el.center?.lat;
    const lon = el.lon ?? el.center?.lon;
    if (!lat || !lon) continue;

    const dedupeKey = `${name.toLowerCase().slice(0, 20)}_${Math.round(lat * 100)}_${Math.round(lon * 100)}`;
    if (seen.has(dedupeKey)) continue;
    seen.add(dedupeKey);

    pending.push({ el, tags, name, lat, lon });
  }

  // Geocoding via Nominatim para locais sem addr:suburb
  const needGeocode = pending.filter(
    ({ tags }) => !(tags["addr:suburb"] || tags["addr:neighbourhood"] || tags["addr:district"])
  );
  const cached   = needGeocode.filter(({ lat, lon }) => geocodeCache[geoKey(lat, lon)] !== undefined);
  const uncached = needGeocode.filter(({ lat, lon }) => geocodeCache[geoKey(lat, lon)] === undefined);

  console.log(`🌍 Geocoding: ${needGeocode.length} locais sem bairro (${cached.length} em cache, ${uncached.length} novos)`);

  if (uncached.length > 0) {
    console.log(`⏳ Buscando ${uncached.length} bairros via Nominatim (~${Math.ceil(uncached.length / 60)} min)...`);
    for (let i = 0; i < uncached.length; i++) {
      const { lat, lon } = uncached[i];
      await reverseGeocode(lat, lon);
      if ((i + 1) % 50 === 0) {
        console.log(`   ${i + 1}/${uncached.length} geocodificados...`);
        saveGeocodeCache(); // salva progresso a cada 50
      }
      await sleep(1100); // Nominatim: max 1 req/s
    }
    saveGeocodeCache();
    console.log(`✅ Nominatim concluído`);
  }

  // Monta rows com dados enriquecidos
  for (const { el, tags, name, lat, lon } of pending) {
    const osmSuburb = tags["addr:suburb"] || tags["addr:neighbourhood"] || tags["addr:district"] || null;
    const osmCity   = tags["addr:city"] || null;

    let suburb, municipality;
    if (osmSuburb) {
      suburb       = osmSuburb;
      municipality = osmCity || "Rio de Janeiro";
    } else {
      const geo    = geocodeCache[geoKey(lat, lon)] || {};
      suburb       = geo.suburb || null;
      municipality = geo.municipality || osmCity || "Rio de Janeiro";
    }

    const uf  = "RJ";
    // Remove sufixo "- RJ" ou "- RJ - RJ" que pode vir do Nominatim ou OSM
    const cleanMunicipality = municipality.replace(/\s*-\s*RJ\s*$/i, "").trim();
    const cleanSuburb = suburb ? suburb.replace(/\s*-\s*RJ\s*$/i, "").trim() : null;
    const city = cleanSuburb
      ? `${cleanSuburb}, ${cleanMunicipality} - ${uf}`
      : `${cleanMunicipality} - ${uf}`;

    const p = classify(name);
    // Anexa bairro ao nome sempre que:
    //   1. há bairro disponível
    //   2. o bairro ainda não consta no nome (evita "Prezunic Taquara Taquara")
    const displayName = (cleanSuburb && !name.toLowerCase().includes(cleanSuburb.toLowerCase()))
      ? `${name} ${cleanSuburb}`
      : name;

    const slug = slugify(displayName, el.id);
    const ctx  = inferContext(tags, displayName);

    rows.push({ name: displayName, lat, lon, slug, city, ctx, ...p });
  }

  return rows;
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  mkdirSync(OUTPUT_DIR, { recursive: true });
  loadGeocodeCache();

  const elements = await fetchMarkets();
  console.log(`✅ ${elements.length} elementos retornados pelo OSM`);

  const rows = await generateSQL(elements);
  console.log(`📍 ${rows.length} locais válidos após deduplicação`);

  // Agrupa por segmento para fácil revisão
  const bySegment = {};
  for (const r of rows) {
    bySegment[r.segment] = (bySegment[r.segment] || 0) + 1;
  }
  console.log("📊 Por segmento:", bySegment);

  const sqlLines = [
    "-- ==========================================================================",
    "-- GoWait — Locais importados via OpenStreetMap (Rio de Janeiro)",
    `-- Gerado em: ${new Date().toISOString()}`,
    `-- Total: ${rows.length} locais`,
    "-- REVISE os segment/size/price_level antes de executar!",
    "-- ==========================================================================",
    "",
    "-- Campos NOT NULL que precisam de valor padrão:",
    "--   opening_hours → null (preencha manualmente depois)",
    "--   checkout_count → null (preencha manualmente depois)",
    "--   base_crowd_factor → 50 (neutro — ajuste conforme local)",
    "",
    "INSERT INTO locations (",
    "  name, slug, latitude, longitude, city,",
    "  segment, vertical, size, price_level,",
    "  base_crowd_factor, location_context,",
    "  is_open, crowd_score, flow, wait_time, trend",
    ") VALUES",
  ];

  const valueLines = rows.map((r, i) => {
    const comma = i < rows.length - 1 ? "," : "";
    const name  = r.name.replace(/'/g, "''");
    const city  = r.city.replace(/'/g, "''");
    return (
      `  ('${name}', '${r.slug}', ${r.lat}, ${r.lon}, '${city}',` +
      ` '${r.segment}', 'mercado', '${r.size}', '${r.price_level}',` +
      ` ${r.base}, '${r.ctx}',` +
      ` false, 50, 'baixo', '10 min', 'estável')${comma}`
    );
  });

  const sql = [...sqlLines, ...valueLines, "ON CONFLICT (slug) DO NOTHING;", "", "-- Rode run_location_snapshot() depois para calcular os scores iniciais:"].join("\n") +
    "\n-- SELECT run_location_snapshot();\n";

  mkdirSync(OUTPUT_DIR, { recursive: true });
  const outPath = join(OUTPUT_DIR, "locations_rj.sql");
  writeFileSync(outPath, sql, "utf8");

  console.log(`\n✅ SQL gerado em: scripts/output/locations_rj.sql`);
  console.log("📋 Próximos passos:");
  console.log("   1. Revise o arquivo (especialmente segment/size dos locais menores)");
  console.log("   2. Cole no SQL Editor do Supabase e execute");
  console.log("   3. Execute: SELECT run_location_snapshot();");
}

main().catch((err) => {
  console.error("❌ Erro:", err.message);
  process.exit(1);
});
