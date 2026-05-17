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

import { writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

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

function inferContext(tags) {
  const addr = [tags["addr:street"] || "", tags["addr:suburb"] || ""].join(" ").toLowerCase();
  if (/shopping|center|mall|galeria/i.test(addr)) return "mall";
  if (/estac|metro|metr|rodoviaria|rod\./i.test(addr)) return "transit_hub";
  return "standalone";
}

// ─── Consulta Overpass API ────────────────────────────────────────────────────

const OVERPASS_ENDPOINTS = [
  "https://overpass.private.coffee/api/interpreter",  // principal — funciona
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
];

async function fetchMarkets() {
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
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          // [out:json] na query já especifica o formato — sem Accept header
        },
        signal: AbortSignal.timeout(70000),
      });

      if (!res.ok) {
        console.log(`   ⚠️  HTTP ${res.status} — tentando próximo...`);
        continue;
      }

      const json = await res.json();
      console.log(`✅ Sucesso via ${endpoint}`);
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

function generateSQL(elements) {
  const rows = [];
  const seen = new Set();

  for (const el of elements) {
    const tags = el.tags || {};
    const name = tags.name || tags["name:pt"] || null;
    if (!name) continue;

    // Coordenadas — node tem lat/lon direto, way tem center
    const lat = el.lat ?? el.center?.lat;
    const lon = el.lon ?? el.center?.lon;
    if (!lat || !lon) continue;

    // Deduplicar por nome + proximidade grosseira (0.001° ≈ 100m)
    const dedupeKey = `${name.toLowerCase().slice(0, 20)}_${Math.round(lat * 100)}_${Math.round(lon * 100)}`;
    if (seen.has(dedupeKey)) continue;
    seen.add(dedupeKey);

    const p     = classify(name);
    const slug  = slugify(name, el.id);
    const ctx   = inferContext(tags);
    const addr  = [
      tags["addr:street"],
      tags["addr:housenumber"],
      tags["addr:suburb"],
      tags["addr:city"] || "Rio de Janeiro",
    ]
      .filter(Boolean)
      .join(", ");

    rows.push({ name, lat, lon, slug, addr, ctx, ...p });
  }

  return rows;
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const elements = await fetchMarkets();
  console.log(`✅ ${elements.length} elementos retornados pelo OSM`);

  const rows = generateSQL(elements);
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
    "  name, slug, latitude, longitude, address,",
    "  segment, vertical, size, price_level,",
    "  base_crowd_factor, location_context,",
    "  is_open, crowd_score, flow, wait_time, trend",
    ") VALUES",
  ];

  const valueLines = rows.map((r, i) => {
    const comma = i < rows.length - 1 ? "," : ";";
    const addr  = r.addr.replace(/'/g, "''");
    const name  = r.name.replace(/'/g, "''");
    return (
      `  ('${name}', '${r.slug}', ${r.lat}, ${r.lon}, '${addr}',` +
      ` '${r.segment}', 'mercado', '${r.size}', '${r.price_level}',` +
      ` ${r.base}, '${r.ctx}',` +
      ` false, 50, 'baixo', '10 min', 'estável')${comma}`
    );
  });

  const sql = [...sqlLines, ...valueLines, "", "-- Rode run_location_snapshot() depois para calcular os scores iniciais:"].join("\n") +
    "\n-- SELECT run_location_snapshot();\n";

  mkdirSync(join(__dirname, "output"), { recursive: true });
  const outPath = join(__dirname, "output", "locations_rj.sql");
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
