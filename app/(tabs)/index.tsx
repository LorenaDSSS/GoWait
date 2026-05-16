import * as Location from "expo-location";
import { useEffect, useRef, useState } from "react";
import {
  ActivityIndicator,
  Animated,
  Easing,
  Linking,
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
const ANIM_OUT_MS = 380;
const ANIM_IN_MS  = 460;
const SLIDE_PX    = 14;

// ─── Subtitle com cross-fade A/B + slide vertical ───────────────────────────
function AnimatedSubtitle() {
  const currentRef  = useRef(0);
  const showingARef = useRef(true);

  const [idxA, setIdxA] = useState(0);
  const [idxB, setIdxB] = useState(1);

  const opA = useRef(new Animated.Value(1)).current;
  const tyA = useRef(new Animated.Value(0)).current;
  const opB = useRef(new Animated.Value(0)).current;
  const tyB = useRef(new Animated.Value(SLIDE_PX)).current;

  useEffect(() => {
    const ease = Easing.out(Easing.cubic);

    const timer = setInterval(() => {
      const next = (currentRef.current + 1) % LOCATION_CONTEXT.length;

      if (showingARef.current) {
        setIdxB(next);
        tyB.setValue(SLIDE_PX);
        opB.setValue(0);
        Animated.parallel([
          Animated.timing(opA, { toValue: 0,        duration: ANIM_OUT_MS, easing: ease, useNativeDriver: true }),
          Animated.timing(tyA, { toValue: -SLIDE_PX, duration: ANIM_OUT_MS, easing: ease, useNativeDriver: true }),
          Animated.timing(opB, { toValue: 1,         duration: ANIM_IN_MS,  easing: ease, useNativeDriver: true }),
          Animated.timing(tyB, { toValue: 0,         duration: ANIM_IN_MS,  easing: ease, useNativeDriver: true }),
        ]).start(() => {
          currentRef.current = next;
          showingARef.current = false;
          tyA.setValue(SLIDE_PX);
        });
      } else {
        setIdxA(next);
        tyA.setValue(SLIDE_PX);
        opA.setValue(0);
        Animated.parallel([
          Animated.timing(opB, { toValue: 0,        duration: ANIM_OUT_MS, easing: ease, useNativeDriver: true }),
          Animated.timing(tyB, { toValue: -SLIDE_PX, duration: ANIM_OUT_MS, easing: ease, useNativeDriver: true }),
          Animated.timing(opA, { toValue: 1,         duration: ANIM_IN_MS,  easing: ease, useNativeDriver: true }),
          Animated.timing(tyA, { toValue: 0,         duration: ANIM_IN_MS,  easing: ease, useNativeDriver: true }),
        ]).start(() => {
          currentRef.current = next;
          showingARef.current = true;
          tyB.setValue(SLIDE_PX);
        });
      }
    }, INTERVAL_MS);

    return () => clearInterval(timer);
  }, []);

  const ctxA = LOCATION_CONTEXT[idxA];
  const ctxB = LOCATION_CONTEXT[idxB];

  const renderContent = (ctx: (typeof LOCATION_CONTEXT)[0]) => (
    <>
      <Text style={styles.subtitleStatic}>Descubra se vale a pena ir </Text>
      <Text style={styles.subtitleWord}>{ctx.prep} {ctx.word}</Text>
      <Text style={styles.subtitleStatic}> agora</Text>
    </>
  );

  return (
    <View style={styles.subtitleContainer}>
      {/* Espaçador invisível para reservar a altura do container */}
      <Text style={[styles.subtitleStatic, styles.subtitleSpacer]}>
        {"Descubra se vale a pena ir\nà farmácia agora"}
      </Text>
      <Animated.Text style={[styles.subtitleLayer, { opacity: opA, transform: [{ translateY: tyA }] }]}>
        {renderContent(ctxA)}
      </Animated.Text>
      <Animated.Text style={[styles.subtitleLayer, { opacity: opB, transform: [{ translateY: tyB }] }]}>
        {renderContent(ctxB)}
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

// Busca o snapshot mais recente de cada local em location_metrics
async function fetchLatestMetrics(locationIds: string[]) {
  if (!locationIds.length) return new Map<string, any>();
  const { data } = await supabase
    .from("location_metrics")
    .select("location_id, crowd_score, created_at")
    .in("location_id", locationIds)
    .order("created_at", { ascending: false });
  const map = new Map<string, any>();
  for (const m of (data || [])) {
    if (!map.has(m.location_id)) map.set(m.location_id, m);
  }
  return map;
}

function enrichMarkets(locations: any[], metricsMap: Map<string, any>) {
  return locations.map((m) => ({
    ...m,
    crowd_score: metricsMap.get(m.id)?.crowd_score ?? null,
    last_snapshot_at: metricsMap.get(m.id)?.created_at ?? null,
  }));
}

function formatSnapshotTime(iso: string | null) {
  if (!iso) return null;
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

// Definido fora do componente para evitar re-criação a cada render
type MarketRowProps = { item: any; isSelected: boolean; onPress: () => void };
function MarketRow({ item, isSelected, onPress }: MarketRowProps) {
  return (
    <TouchableOpacity
      style={[styles.marketRow, isSelected && styles.marketRowActive]}
      onPress={onPress}
      activeOpacity={0.7}
    >
      <PulsingDot color={getFlowColor(item.flow)} />
      <View style={styles.marketRowText}>
        <Text style={styles.marketRowName}>{item.name}</Text>
        <Text style={styles.marketRowDecision}>{getDecision(item.flow)}</Text>
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
        <Text style={styles.reportName}>{market.name}</Text>
        <View style={styles.reportRow}>
          <View style={styles.reportChip}>
            <Text style={styles.chipLabel}>Fluxo</Text>
            <Text
              style={[styles.chipValue, { color: getFlowColor(market.flow) }]}
              numberOfLines={1}
            >
              {getFlowLabel(market.flow ?? "")}
            </Text>
          </View>
          <View style={styles.reportChip}>
            <Text style={styles.chipLabel}>Tendência</Text>
            <Text style={styles.chipValue} numberOfLines={1}>
              {market.trend ?? "—"}
            </Text>
          </View>
          {market.crowd_score != null && (
            <View style={styles.reportChip}>
              <Text style={styles.chipLabel}>Score</Text>
              <Text
                style={[styles.chipValue, { color: getFlowColor(market.flow) }]}
                numberOfLines={1}
              >
                {market.crowd_score}/100
              </Text>
            </View>
          )}
        </View>
        <View style={styles.divider} />
        <Text style={styles.reportDecision}>{getDecision(market.flow ?? "")}</Text>
        <Text style={styles.reportWait}>
          {"⏱ " + getWaitMessage(market.flow ?? "", market.wait_time ?? "")}
        </Text>

        {/* Relato inline — dado mais valioso: usuário informa como está agora */}
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
              <Text style={styles.inlineReportLabel}>Como está agora?</Text>
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

        {/* CTA principal — sinal de maior intenção */}
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
          const metricsMap = await fetchLatestMetrics(markets.map((m: any) => m.id));
          const enriched = enrichMarkets(markets, metricsMap);
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
    const metricsMap = await fetchLatestMetrics(markets.map((m: any) => m.id));
    const enriched = enrichMarkets(markets, metricsMap);

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
    const metricsMap = await fetchLatestMetrics(markets.map((m: any) => m.id));
    const enriched = enrichMarkets(markets, metricsMap);
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
          {results.map((item) => (
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
              <PulsingDot color={getFlowColor(item.flow)} />
              <Text style={styles.searchResultName}>{item.name}</Text>
            </TouchableOpacity>
          ))}
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
