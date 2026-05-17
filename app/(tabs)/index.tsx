import * as Location from "expo-location";
import { useEffect, useRef, useState } from "react";
import {
  ActivityIndicator,
  Animated,
  Easing,
  Linking,
  Modal,
  Pressable,
  ScrollView,
  Text,
  TextInput,
  TouchableOpacity,
  View
} from "react-native";
import MapView, { Marker, Polyline } from "react-native-maps";
import { FeedbackValue, SignalSource, trackFeedback, trackSignal } from "../../lib/signals";
import { supabase } from "../../lib/supabase";
import { styles } from "./index.styles";

// ─── Contextos rotativos ────────────────────────────────────────────────────
const LOCATION_CONTEXT = [
  { prep: "ao",   word: "mercado"  },
  { prep: "à",    word: "farmácia" },
  { prep: "ao",   word: "varejo"   },
  { prep: "à",    word: "loja"     },
  { prep: "a um", word: "local"    },
];

const INTERVAL_MS = 3500;
const ANIM_OUT_MS = 430;
const ANIM_IN_MS  = 540;
const SLIDE_PX    = 14;

// ─── Subtitle com fade + slide apenas na palavra variável ──────────────────
function AnimatedSubtitle() {
  const [wordIndex, setWordIndex] = useState(0);
  const opacity    = useRef(new Animated.Value(1)).current;
  const translateY = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    const ease = Easing.out(Easing.cubic);

    const timer = setInterval(() => {
      // Fase 1: sai (fade out + sobe)
      Animated.parallel([
        Animated.timing(opacity,    { toValue: 0,        duration: ANIM_OUT_MS, easing: ease, useNativeDriver: true }),
        Animated.timing(translateY, { toValue: -SLIDE_PX, duration: ANIM_OUT_MS, easing: ease, useNativeDriver: true }),
      ]).start(() => {
        // Troca o texto enquanto está invisível
        setWordIndex(prev => (prev + 1) % LOCATION_CONTEXT.length);
        translateY.setValue(SLIDE_PX); // posiciona abaixo
        // Fase 2: entra (fade in + sobe até centro)
        Animated.parallel([
          Animated.timing(opacity,    { toValue: 1, duration: ANIM_IN_MS, easing: ease, useNativeDriver: true }),
          Animated.timing(translateY, { toValue: 0, duration: ANIM_IN_MS, easing: ease, useNativeDriver: true }),
        ]).start();
      });
    }, INTERVAL_MS);

    return () => clearInterval(timer);
  }, []);

  const ctx = LOCATION_CONTEXT[wordIndex];

  return (
    <View style={styles.subtitleContainer}>
      <Text style={styles.subtitleStatic}>Descubra se vale a pena ir </Text>
      <Animated.Text style={[styles.subtitleWord, { opacity, transform: [{ translateY }] }]}>
        {ctx.prep} {ctx.word}<Text style={styles.subtitleStatic}> agora</Text>
      </Animated.Text>
    </View>
  );
}
// ─── Bolinha pulso ─────────────────────────────────────────────────────────
function PulsingDot({ color }: { color: string }) {
  const scale   = useRef(new Animated.Value(1)).current;
  const opacity = useRef(new Animated.Value(0.45)).current;

  useEffect(() => {
    const ease = Easing.out(Easing.ease);
    const anim = Animated.loop(
      Animated.sequence([
        Animated.parallel([
          Animated.timing(scale,   { toValue: 2.4,  duration: 1400, easing: ease, useNativeDriver: true }),
          Animated.timing(opacity, { toValue: 0,    duration: 1400, easing: ease, useNativeDriver: true }),
        ]),
        Animated.delay(600),
        Animated.parallel([
          Animated.timing(scale,   { toValue: 1,   duration: 0, useNativeDriver: true }),
          Animated.timing(opacity, { toValue: 0.5, duration: 0, useNativeDriver: true }),
        ]),
      ])
    );
    anim.start();
    return () => anim.stop();
  }, []);

  return (
    <View style={styles.dotWrapper}>
      <Animated.View style={[styles.dotRing, { backgroundColor: color, transform: [{ scale }], opacity }]} />
      {/* shadowColor inline pois é dinâmico — propriedades estáticas ficam no StyleSheet */}
      <View style={[styles.dotCore, { backgroundColor: color, shadowColor: color }]} />
    </View>
  );
}

// ─── Helpers (fora do componente) ────────────────────────────────────────────

// Calcula status de funcionamento a partir dos dados do location
// (lê opening_hours e closing_buffer_minutes — já vêm no objeto market)
type LocationStatus =
  | { status: "open" }
  | { status: "closing_soon"; closesInMinutes: number }
  | { status: "closed"; opensAt: string | null };

function getLocationStatus(market: any): LocationStatus {
  const hours  = market.opening_hours as Record<string, any> | null;
  const buffer = (market.closing_buffer_minutes as number) ?? 0;
  const DAYS   = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
  const now    = new Date();
  const nowMs  = (now.getHours() * 60 + now.getMinutes()) * 60000;
  const key    = DAYS[now.getDay()];
  const day    = hours?.[key] ?? hours?.["default"];

  // Calcula abertura/fechamento localmente — não depende de is_open do banco.
  // Isso elimina o delay de até 15 min entre o pg_cron atualizar is_open
  // e o app refletir o estado real da loja.
  if (day && !day.closed && day.open && day.close) {
    const [oh, om] = (day.open  as string).split(":").map(Number);
    const [ch, cm] = (day.close as string).split(":").map(Number);
    const openMs   = (oh * 60 + om) * 60000;
    const closeMs  = (ch * 60 + cm) * 60000;

    // Antes do horário de abertura → fechado
    if (nowMs < openMs) {
      return { status: "closed", opensAt: day.open };
    }

    // Após o horário de fechamento (com buffer) → fechado
    if (nowMs >= closeMs + buffer * 60000) {
      // Tenta mostrar a abertura do dia seguinte
      const nextKey = DAYS[(now.getDay() + 1) % 7];
      const nextDay = hours?.[nextKey] ?? hours?.["default"];
      return { status: "closed", opensAt: nextDay?.open ?? day.open ?? null };
    }

    // Dentro da janela de aviso de fechamento
    const minsLeft = Math.round((closeMs + buffer * 60000 - nowMs) / 60000);
    if (minsLeft > 0 && minsLeft <= Math.max(30, buffer)) {
      return { status: "closing_soon", closesInMinutes: minsLeft };
    }

    return { status: "open" };
  }

  // Sem opening_hours cadastrado: confia em is_open do banco como fallback
  if (market.is_open === false) {
    return { status: "closed", opensAt: null };
  }
  return { status: "open" };
}

function getDecision(flow: string) {
  if (flow === "baixo") return "Vale a pena ir agora";
  if (flow === "médio") return "Pode ter movimento";
  if (flow === "alto") return "Melhor esperar";
  return "Sem dados";
}

function getWaitMessage(flow: string, waitTime: string) {
  if (flow === "baixo") return "Sem espera prevista, pode ir!";
  return `Você deve esperar cerca de ${waitTime} para chegar ao local`;
}

// Paleta GoWait — extraída da logo
function getFlowColor(flow: string) {
  if (flow === "baixo") return "#50b1d6"; // azul claro — fluido
  if (flow === "médio") return "#b399e9"; // roxo suave — ativo
  if (flow === "alto")  return "#fabf97"; // pêssego    — intenso
  return "#e0e0e2";
}

function getFlowLabel(flow: string) {
  if (flow === "baixo") return "Fluido";
  if (flow === "médio") return "Ativo";
  if (flow === "alto")  return "Intenso";
  return "—";
}

// Snapshot stale = local aberto mas o último snapshot é anterior ao horário de abertura de hoje
function isMarketDataStale(market: any, isClosed: boolean): boolean {
  if (isClosed) return false;
  const snapshotDate = market.last_snapshot_at ? new Date(market.last_snapshot_at) : null;
  if (!snapshotDate) return false;
  const hours = market.opening_hours as Record<string, any> | null;
  const DAYS  = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
  const now   = new Date();
  const day   = hours?.[DAYS[now.getDay()]] ?? hours?.["default"];
  if (!day?.open) return false;
  const [oh, om] = (day.open as string).split(":").map(Number);
  const openToday = new Date(now.getFullYear(), now.getMonth(), now.getDate(), oh, om, 0);
  return snapshotDate < openToday;
}
function haversine(lat1: number, lon1: number, lat2: number, lon2: number) {
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

function formatDistance(km: number) {
  if (km < 1) return `${Math.round(km * 1000)} m`;
  return `${km.toFixed(1)} km`;
}

// crowd_score, trend, flow, wait_time e snapshot_at são escritos direto
// em locations pelo run_location_snapshot() → nenhuma query extra necessária.
function enrichMarkets(locations: any[]) {
  return locations.map((m) => ({
    ...m,
    last_snapshot_at: m.snapshot_at ?? null,
  }));
}

function formatSnapshotTime(iso: string | null) {
  if (!iso) return null;
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

// ─── Tooltip modal para chips informativos ────────────────────────────────────
type ChipTooltip = { title: string; body: string };

const CHIP_INFO: Record<string, ChipTooltip> = {
  fluxo: {
    title: "Fluxo",
    body: "Indica o nível de movimento do local agora.\n\n" +
      "• Fluido — poucas pessoas, sem espera\n" +
      "• Ativo — movimento moderado, pode ter fila curta\n" +
      "• Intenso — local com muita gente, espera provável",
  },
  tendencia: {
    title: "Tendência",
    body: "Indica se o fluxo vai aumentar ou diminuir na próxima hora.\n\n" +
      "• Subindo — vai ficar mais cheio em breve\n" +
      "• Estável — movimento deve se manter\n" +
      "• Caindo — deve esvaziar na próxima hora",
  },
  score: {
    title: "Score",
    body: "Pontuação de lotação estimada, de 0 a 100.\n\n" +
      "Calculada com base no horário, dia da semana, tipo e tamanho do local.",
  },
  scoreIA: {
    title: "Score IA",
    body: "Pontuação inteligente que combina três fontes:\n\n" +
      "• Previsão heurística (horário, dia, tipo de local)\n" +
      "• Comportamento real dos usuários (cliques, tempo de visualização)\n" +
      "• Relatos diretos de quem visitou o local\n\n" +
      "Quanto mais pessoas interagem, mais preciso fica.",
  },
};

function ChipWithTooltip({
  label,
  value,
  valueColor,
  tooltipKey,
}: {
  label: string;
  value: string;
  valueColor?: string;
  tooltipKey: string;
}) {
  const [visible, setVisible] = useState(false);
  const info = CHIP_INFO[tooltipKey];
  return (
    <>
      <TouchableOpacity
        style={styles.reportChip}
        onPress={() => setVisible(true)}
        activeOpacity={0.7}
      >
        <View style={styles.chipLabelRow}>
          <Text style={styles.chipLabel}>{label}</Text>
          <Text style={styles.chipHint}> ⓘ</Text>
        </View>
        <Text style={[styles.chipValue, valueColor ? { color: valueColor } : undefined]} numberOfLines={1}>
          {value}
        </Text>
      </TouchableOpacity>

      <Modal transparent animationType="fade" visible={visible} onRequestClose={() => setVisible(false)}>
        <Pressable style={styles.tooltipOverlay} onPress={() => setVisible(false)}>
          <Pressable style={styles.tooltipCard} onPress={() => {}}>
            <Text style={styles.tooltipTitle}>{info?.title}</Text>
            <Text style={styles.tooltipBody}>{info?.body}</Text>
            <TouchableOpacity onPress={() => setVisible(false)} style={styles.tooltipClose}>
              <Text style={styles.tooltipCloseText}>Fechar</Text>
            </TouchableOpacity>
          </Pressable>
        </Pressable>
      </Modal>
    </>
  );
}

// Definido fora do componente para evitar re-criação a cada render
type MarketRowProps = { item: any; isSelected: boolean; onPress: () => void };
function MarketRow({ item, isSelected, onPress }: MarketRowProps) {
  const locStatus = getLocationStatus(item);
  const closed    = locStatus.status === "closed";
  const stale     = isMarketDataStale(item, closed);
  const dotColor  = closed || stale ? "#C8CDD8" : getFlowColor(item.flow);
  return (
    <TouchableOpacity
      style={[styles.marketRow, isSelected && styles.marketRowActive, closed && styles.marketRowClosed]}
      onPress={onPress}
      activeOpacity={0.7}
    >
      <PulsingDot color={dotColor} />
      <View style={styles.marketRowText}>
        <Text style={[styles.marketRowName, closed && styles.marketRowNameClosed]}>{item.name}</Text>
        {closed ? (
          <Text style={styles.marketRowClosedLabel}>
            {(locStatus as any).opensAt
              ? `Fechado · Abre às ${(locStatus as any).opensAt}`
              : "Fechado agora"}
          </Text>
        ) : (
          <Text style={styles.marketRowDecision}>{getDecision(item.flow)}</Text>
        )}
      </View>
    </TouchableOpacity>
  );
}

// ─── Opções de relato inline ─────────────────────────────────────────────────

const FEEDBACK_OPTIONS: { value: FeedbackValue; label: string; color: string }[] = [
  { value: "vazio",  label: "Vazio",  color: "#50b1d6" },
  { value: "normal", label: "Normal", color: "#b399e9" },
  { value: "cheio",  label: "Cheio",  color: "#fabf97" },
];

// ─── Dashboard do local selecionado ─────────────────────────────────────────

type MarketDashboardProps = { market: any; source: SignalSource };
function MarketDashboard({ market, source }: MarketDashboardProps) {
  const snapshotTime  = formatSnapshotTime(market.last_snapshot_at ?? null);
  const mountTimeRef  = useRef(Date.now());
  const [localFeedback, setLocalFeedback] = useState<FeedbackValue | null>(null);
  const locationStatus = getLocationStatus(market);
  const isClosed       = locationStatus.status === "closed";

  const isSnapshotStale = isMarketDataStale(market, isClosed);

  // Registra dwell time quando o dashboard é fechado
  useEffect(() => {
    return () => {
      const dwell = Math.round((Date.now() - mountTimeRef.current) / 1000);
      trackSignal({
        location_id:        market.id,
        event_type:         "view",
        source,
        flow_at_event:      market.flow       ?? null,
        score_at_event:     market.crowd_score ?? null,
        dwell_time_seconds: dwell,
      });
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [market.id]);
  return (
    <View style={{ flex: 1 }}>
      <View style={styles.report}>
        {/* Badge de horário — fechado ou fechando em breve */}
        {locationStatus.status === "closed" && (
          <View style={styles.closedBadge}>
            <Text style={styles.closedBadgeText}>
              {(locationStatus as any).opensAt
                ? `Fechado · Abre às ${(locationStatus as any).opensAt}`
                : "Fechado agora"}
            </Text>
          </View>
        )}
        {locationStatus.status === "closing_soon" && (
          <View style={styles.closingSoonBadge}>
            <Text style={styles.closingSoonBadgeText}>
              Fecha em {(locationStatus as any).closesInMinutes} min
            </Text>
          </View>
        )}

        <Text style={styles.reportName}>{market.name}</Text>

        {isClosed ? (
          <View style={styles.closedPlaceholder}>
            <Text style={styles.closedPlaceholderText}>
              As informações de fluxo estarão disponíveis quando o local abrir.
            </Text>
          </View>
        ) : isSnapshotStale ? (
          <View style={styles.closedPlaceholder}>
            <Text style={styles.closedPlaceholderText}>
              O local acabou de abrir. Dados sendo calculados — disponíveis em até 15 min.
            </Text>
          </View>
        ) : (
          <>
            <View style={styles.reportRow}>
              <ChipWithTooltip
                label="Fluxo"
                value={getFlowLabel(market.flow ?? "")}
                valueColor={getFlowColor(market.flow)}
                tooltipKey="fluxo"
              />
              <ChipWithTooltip
                label="Tendência"
                value={market.trend ?? "—"}
                tooltipKey="tendencia"
              />
              {(market.intelligence_score ?? market.crowd_score) != null && (
                <ChipWithTooltip
                  label={market.intelligence_score != null ? "Score IA" : "Score"}
                  value={`${(market.intelligence_score ?? market.crowd_score)}/100`}
                  valueColor={getFlowColor(market.flow)}
                  tooltipKey={market.intelligence_score != null ? "scoreIA" : "score"}
                />
              )}
            </View>
            <View style={styles.divider} />
            <Text style={styles.reportDecision}>{getDecision(market.flow ?? "")}</Text>
            <Text style={styles.reportWait}>
              {"⏱ " + getWaitMessage(market.flow ?? "", market.wait_time ?? "")}
            </Text>
          </>
        )}

        {/* Relato inline — só exibido quando o local está aberto */}
        {!isClosed && (
          <View style={styles.inlineReportSection}>
            {localFeedback ? (
              <Text
                style={[
                  styles.inlineReportConfirm,
                  { color: FEEDBACK_OPTIONS.find((o) => o.value === localFeedback)?.color },
                ]}
              >
                ✓ Obrigado pelo relato!
              </Text>
            ) : (
              <>
                <Text style={styles.inlineReportLabel}>Como está o fluxo agora?</Text>
                <View style={styles.inlineReportBtns}>
                  {FEEDBACK_OPTIONS.map((opt) => (
                    <TouchableOpacity
                      key={opt.value}
                      style={[styles.inlineReportBtn, { borderColor: opt.color }]}
                      onPress={() => {
                        setLocalFeedback(opt.value);
                        trackFeedback(
                          market.id,
                          opt.value,
                          market.flow ?? null,
                          market.crowd_score ?? null,
                        );
                      }}
                      activeOpacity={0.75}
                    >
                      <View style={[styles.feedbackDot, { backgroundColor: opt.color }]} />
                      <Text style={styles.inlineReportBtnText}>{opt.label}</Text>
                    </TouchableOpacity>
                  ))}
                </View>
              </>
            )}
          </View>
        )}

        {/* CTA principal — oculto se fechado */}
        {!isClosed && (
          <TouchableOpacity
            style={styles.navigateBtn}
            activeOpacity={0.82}
            onPress={() => {
              trackSignal({
                location_id:    market.id,
                event_type:     "navigate",
                source,
                flow_at_event:  market.flow        ?? null,
                score_at_event: market.crowd_score ?? null,
              });
              const url = `https://www.google.com/maps/dir/?api=1&destination=${market.latitude},${market.longitude}&travelmode=walking`;
              Linking.openURL(url);
            }}
          >
            <Text style={styles.navigateBtnText}>Ir agora</Text>
          </TouchableOpacity>
        )}

        {snapshotTime && (
          <Text style={styles.snapshotTime}>Atualizado às {snapshotTime}</Text>
        )}
      </View>
    </View>
  );
}

// ─── Componente principal ──────────────────────────────────────────────────────

export default function Home() {
  const [search, setSearch] = useState("");
  const [results, setResults] = useState<any[]>([]);
  const [nearbyMarkets, setNearbyMarkets] = useState<any[]>([]);
  const [selectedMarket, setSelectedMarket] = useState<any>(null);
  const [loadingLocation, setLoadingLocation] = useState(true);
  const [userCoords, setUserCoords] = useState<{ latitude: number; longitude: number } | null>(null);

  const mapRef              = useRef<MapView>(null);
  const userCoordsRef       = useRef<{ latitude: number; longitude: number } | null>(null);
  const lastSourceRef       = useRef<SignalSource>("nearby");
  const dismissedIdsRef     = useRef<Set<string>>(new Set());

  const isSearching = search.trim().length > 0;
  const showHero = !selectedMarket && !isSearching;

  const handleBack = () => {
    if (selectedMarket) {
      dismissedIdsRef.current.add(selectedMarket.id);
      trackSignal({
        location_id:    selectedMarket.id,
        event_type:     "dismiss",
        source:         lastSourceRef.current,
        flow_at_event:  selectedMarket.flow        ?? null,
        score_at_event: selectedMarket.crowd_score ?? null,
      });
    }
    setSearch("");
    setResults([]);
    setSelectedMarket(null);
  };

  useEffect(() => {
    loadAll();
  }, []);

  // Realtime: atualiza lista e dashboard quando snapshots chegam
  // Pré-requisito: habilitar a tabela "markets" em Database > Replication no Supabase
  useEffect(() => {
    const channel = supabase
      .channel("locations-live")
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "locations" },
        async () => {
          const { data } = await supabase.from("locations").select("*");
          const markets = data || [];
          const enriched = enrichMarkets(markets);
          const coords = userCoordsRef.current;
          if (coords) {
            const sorted = [...enriched]
              .map((m: any) => ({ ...m, dist: haversine(coords.latitude, coords.longitude, m.latitude, m.longitude) }))
              .sort((a: any, b: any) => a.dist - b.dist)
              .slice(0, 5);
            setNearbyMarkets(sorted);
          } else {
            setNearbyMarkets(enriched.slice(0, 5));
          }
          // Atualiza o mercado selecionado se estiver aberto
          setSelectedMarket((prev: any) => {
            if (!prev) return null;
            return enriched.find((m: any) => m.id === prev.id) ?? prev;
          });
        }
      )
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, []);

  const loadAll = async () => {
    const { data } = await supabase.from("locations").select("*");
    const markets = data || [];
    const enriched = enrichMarkets(markets);

    const { status } = await Location.requestForegroundPermissionsAsync();
    if (status === "granted") {
      const loc = await Location.getCurrentPositionAsync({});
      const { latitude, longitude } = loc.coords;
      setUserCoords({ latitude, longitude });
      userCoordsRef.current = { latitude, longitude };
      const sorted = [...enriched]
        .map((m) => ({ ...m, dist: haversine(latitude, longitude, m.latitude, m.longitude) }))
        .sort((a, b) => a.dist - b.dist)
        .slice(0, 5);
      setNearbyMarkets(sorted);
    } else {
      setNearbyMarkets(enriched.slice(0, 5));
    }
    setLoadingLocation(false);
  };

  const handleSelect = (market: any, source: SignalSource = "nearby") => {
    lastSourceRef.current = source;
    // Se o usuário voltou a um local que havia fechado → event_type = "return"
    const wasDissmissed = dismissedIdsRef.current.has(market.id);
    trackSignal({
      location_id:    market.id,
      event_type:     wasDissmissed ? "return" : "click",
      source,
      flow_at_event:  market.flow        ?? null,
      score_at_event: market.crowd_score ?? null,
    });
    setSelectedMarket(market);
    mapRef.current?.animateToRegion(
      {
        latitude: market.latitude - 0.003,
        longitude: market.longitude,
        latitudeDelta: 0.01,
        longitudeDelta: 0.01,
      },
      800
    );
  };

  const handleSearch = async (text: string) => {
    setSearch(text);

    if (!text.trim()) {
      setResults([]);
      setSelectedMarket(null);
      return;
    }

    const { data } = await supabase
      .from("locations")
      .select("*")
      .ilike("name", `%${text}%`);

    const markets = data || [];
    const enriched = enrichMarkets(markets);
    setResults(enriched);

    // Registra sinal de busca para cada local encontrado (mínimo 3 chars para evitar ruído)
    if (text.trim().length >= 3) {
      enriched.forEach((m: any) => {
        trackSignal({
          location_id:    m.id,
          event_type:     "search",
          source:         "search",
          flow_at_event:  m.flow        ?? null,
          score_at_event: m.crowd_score ?? null,
        });
      });
    }
  };

  return (
    <View style={styles.container}>

      {/* Hero — some quando não há seleção nem busca ativa */}
      {showHero && (
        <View style={styles.hero}>
          <Text style={styles.title}>GoWait</Text>
          <AnimatedSubtitle />
        </View>
      )}

      <TextInput
        style={styles.input}
        placeholder="Pesquisar locais..."
        placeholderTextColor="#999"
        value={search}
        onChangeText={handleSearch}
      />

      {/* Resultados de busca — dropdown compacto acima do mapa */}
      {isSearching && results.length > 0 && (
        <View style={styles.searchResults}>
          {results.map((item) => {
              const locStatus = getLocationStatus(item);
              const closed    = locStatus.status === "closed";
              const stale     = isMarketDataStale(item, closed);
              const dotColor  = closed || stale ? "#C8CDD8" : getFlowColor(item.flow);
              return (
                <TouchableOpacity
                  key={String(item.id)}
                  style={[
                    styles.searchResultRow,
                    selectedMarket?.id === item.id && styles.searchResultRowActive,
                  ]}
                  onPress={() => {
                    setSearch(item.name);
                    setResults([]);
                    handleSelect(item, "search");
                  }}
                  activeOpacity={0.7}
                >
                  <PulsingDot color={dotColor} />
                  <Text style={styles.searchResultName}>{item.name}</Text>
                </TouchableOpacity>
              );
            })}
        </View>
      )}

      <View style={styles.mapContainer}>
        <MapView
          ref={mapRef}
          style={styles.map}
          showsUserLocation
          showsMyLocationButton={false}
          initialRegion={{
            latitude: -22.9028,
            longitude: -43.5615,
            latitudeDelta: 0.05,
            longitudeDelta: 0.05,
          }}
        >
          {selectedMarket && (
            <Marker
              coordinate={{
                latitude: selectedMarket.latitude,
                longitude: selectedMarket.longitude,
              }}
            />
          )}

          {selectedMarket && userCoords && (
            <Polyline
              coordinates={[userCoords, { latitude: selectedMarket.latitude, longitude: selectedMarket.longitude }]}
              strokeColor="#3970c3"
              strokeWidth={3}
              lineDashPattern={[8, 6]}
            />
          )}
        </MapView>

        {/* Overlay de informação — aparece no topo do mapa ao selecionar */}
        {selectedMarket && (
          <View style={styles.mapInfoBubble}>
            <Text style={styles.mapInfoName} numberOfLines={1}>{selectedMarket.name}</Text>
            {userCoords && (
              <Text style={styles.mapInfoDistance}>
                📍 {formatDistance(haversine(userCoords.latitude, userCoords.longitude, selectedMarket.latitude, selectedMarket.longitude))} de você
              </Text>
            )}
          </View>
        )}
      </View>

      {/* Área abaixo do mapa */}
      <View style={styles.listArea}>

        {/* Cabeçalho: "Locais próximos" ou botão "Voltar" */}
        {(isSearching || selectedMarket) ? (
          <TouchableOpacity onPress={handleBack} style={styles.voltarBtn} activeOpacity={0.7}>
            <Text style={styles.voltarBtnText}>‹  Voltar</Text>
          </TouchableOpacity>
        ) : (
          !loadingLocation && (
            <Text style={styles.sectionTitle}>Locais próximos de você</Text>
          )
        )}

        {isSearching ? (
          selectedMarket ? (
            <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={{ flexGrow: 1 }}>
              <MarketDashboard
                key={selectedMarket.id}
                market={selectedMarket}
                source={lastSourceRef.current}
              />
            </ScrollView>
          ) : results.length === 0 ? (
            <Text style={[styles.emptyText, { marginTop: 16 }]}>
              Nenhum local encontrado
            </Text>
          ) : null
        ) : loadingLocation ? (
          <ActivityIndicator color="#888" style={{ marginTop: 12 }} />
        ) : selectedMarket ? (
          <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={{ flexGrow: 1 }}>
            <MarketDashboard
              key={selectedMarket.id}
              market={selectedMarket}
              source={lastSourceRef.current}
            />
          </ScrollView>
        ) : (
          <ScrollView
            showsVerticalScrollIndicator={false}
            keyboardShouldPersistTaps="handled"
          >
            {nearbyMarkets.map((item) => (
              <MarketRow
                key={String(item.id)}
                item={item}
                isSelected={false}
                onPress={() => handleSelect(item)}
              />
            ))}
          </ScrollView>
        )}
      </View>

    </View>
  );
}
