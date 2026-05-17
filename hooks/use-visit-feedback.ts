import AsyncStorage from "@react-native-async-storage/async-storage";

// ─── Tipos ────────────────────────────────────────────────────────────────────

export interface PendingVisit {
  locationId:    string;
  locationName:  string;
  clickedAt:     number; // timestamp ms
  lat:           number;
  lon:           number;
  flow:          string | null;
  score:         number | null;
  feedbackAsked: boolean;
}

// ─── Constantes ───────────────────────────────────────────────────────────────

const STORAGE_KEY = "gowait:pending_visits";

/** Tempo mínimo desde o clique para pedir feedback (20 min) */
const MIN_ELAPSED_MS  = 20 * 60 * 1000;

/** Tempo máximo desde o clique (3h — após isso a visita já esfriou) */
const MAX_ELAPSED_MS  = 3 * 60 * 60 * 1000;

/** Raio máximo em km para considerar que o usuário "foi" ao local */
const PROXIMITY_KM    = 0.5;

// ─── Helpers ─────────────────────────────────────────────────────────────────

function haversine(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((lat1 * Math.PI) / 180) *
    Math.cos((lat2 * Math.PI) / 180) *
    Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

async function loadAll(): Promise<PendingVisit[]> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

async function saveAll(visits: PendingVisit[]): Promise<void> {
  try {
    // Guardar apenas visitas das últimas 3h para não acumular lixo
    const cutoff = Date.now() - MAX_ELAPSED_MS;
    const clean  = visits.filter((v) => v.clickedAt >= cutoff);
    await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(clean));
  } catch {}
}

// ─── API pública ──────────────────────────────────────────────────────────────

/**
 * Registra um clique em um local para monitorar possível visita.
 * Chamado em handleSelect() no index.tsx.
 */
export async function registerClick(params: {
  locationId:   string;
  locationName: string;
  lat:          number;
  lon:          number;
  flow:         string | null;
  score:        number | null;
}): Promise<void> {
  const visits = await loadAll();

  // Substitui entrada anterior do mesmo local se existir
  const filtered = visits.filter((v) => v.locationId !== params.locationId);
  filtered.push({
    locationId:    params.locationId,
    locationName:  params.locationName,
    clickedAt:     Date.now(),
    lat:           params.lat,
    lon:           params.lon,
    flow:          params.flow,
    score:         params.score,
    feedbackAsked: false,
  });

  await saveAll(filtered);
}

/**
 * Verifica se há visita pendente que se qualifica para pedido de feedback.
 *
 * Critérios (todos devem ser verdadeiros):
 *   1. Tempo desde o clique ≥ 20 min e ≤ 3h
 *   2. Usuário está a ≤ 500m do local
 *   3. Ainda não pedimos feedback por essa visita
 *
 * Retorna a PendingVisit elegível ou null.
 */
export async function getPendingFeedback(
  userLat: number,
  userLon: number,
): Promise<PendingVisit | null> {
  const visits  = await loadAll();
  const now     = Date.now();

  for (const visit of visits) {
    if (visit.feedbackAsked) continue;

    const elapsed = now - visit.clickedAt;
    if (elapsed < MIN_ELAPSED_MS) continue;
    if (elapsed > MAX_ELAPSED_MS) continue;

    const dist = haversine(userLat, userLon, visit.lat, visit.lon);
    if (dist > PROXIMITY_KM) continue;

    return visit;
  }

  return null;
}

/**
 * Marca a visita como "feedback já solicitado" para não perguntar de novo.
 */
export async function markFeedbackAsked(locationId: string): Promise<void> {
  const visits  = await loadAll();
  const updated = visits.map((v) =>
    v.locationId === locationId ? { ...v, feedbackAsked: true } : v,
  );
  await saveAll(updated);
}
