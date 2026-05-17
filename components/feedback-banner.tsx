import React from "react";
import { StyleSheet, Text, TouchableOpacity, View } from "react-native";

import { markFeedbackAsked, PendingVisit } from "../hooks/use-visit-feedback";
import { FeedbackValue, trackFeedback } from "../lib/signals";

// ─── Tipos ────────────────────────────────────────────────────────────────────

interface FeedbackBannerProps {
  visit:      PendingVisit;
  onDismiss:  () => void;
}

// ─── Opções de resposta ───────────────────────────────────────────────────────

const OPTIONS: { label: string; value: FeedbackValue | "skip" }[] = [
  { label: "😌 Tranquilo", value: "tranquilo" },
  { label: "🙂 Moderado",  value: "moderado"  },
  { label: "😬 Cheio",     value: "cheio"     },
  { label: "Não fui",      value: "skip"      },
];

// ─── Componente ───────────────────────────────────────────────────────────────

export function FeedbackBanner({ visit, onDismiss }: FeedbackBannerProps) {
  const handle = async (value: FeedbackValue | "skip") => {
    await markFeedbackAsked(visit.locationId);

    if (value !== "skip") {
      trackFeedback(visit.locationId, value, visit.flow, visit.score);
    }

    onDismiss();
  };

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Você foi ao {visit.locationName}?</Text>
      <Text style={styles.sub}>Como estava quando chegou?</Text>
      <View style={styles.options}>
        {OPTIONS.map((opt) => (
          <TouchableOpacity
            key={opt.value}
            style={[styles.btn, opt.value === "skip" && styles.btnSkip]}
            onPress={() => handle(opt.value)}
            activeOpacity={0.75}
          >
            <Text style={[styles.btnText, opt.value === "skip" && styles.btnTextSkip]}>
              {opt.label}
            </Text>
          </TouchableOpacity>
        ))}
      </View>
    </View>
  );
}

// ─── Estilos ──────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: {
    position:        "absolute",
    bottom:          80,
    left:            16,
    right:           16,
    backgroundColor: "#1c1c1e",
    borderRadius:    16,
    padding:         16,
    shadowColor:     "#000",
    shadowOffset:    { width: 0, height: 4 },
    shadowOpacity:   0.3,
    shadowRadius:    8,
    elevation:       8,
    zIndex:          100,
  },
  title: {
    color:      "#ffffff",
    fontSize:   15,
    fontWeight: "600",
    marginBottom: 2,
  },
  sub: {
    color:        "#a1a1aa",
    fontSize:     13,
    marginBottom: 12,
  },
  options: {
    flexDirection:  "row",
    flexWrap:       "wrap",
    gap:            8,
  },
  btn: {
    backgroundColor: "#2c2c2e",
    borderRadius:    10,
    paddingVertical:  8,
    paddingHorizontal: 12,
  },
  btnSkip: {
    backgroundColor: "transparent",
    borderWidth:     1,
    borderColor:     "#3f3f46",
  },
  btnText: {
    color:      "#ffffff",
    fontSize:   13,
    fontWeight: "500",
  },
  btnTextSkip: {
    color: "#71717a",
  },
});
