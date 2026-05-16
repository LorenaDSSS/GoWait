import type { Flow, MarketSize, MarketType, PriceLevel } from "./types";

// ─── Limiares de fluxo ────────────────────────────────────────────────────────

export const FLOW_SCORE_RANGES: Record<Flow, [min: number, max: number]> = {
  baixo: [0, 35],
  médio: [36, 70],
  alto: [71, 100],
};

// ─── Tempos de espera por faixa de fluxo (minutos) ───────────────────────────

export const WAIT_RANGES: Record<Flow, [min: number, max: number]> = {
  baixo: [5, 10],
  médio: [12, 20],
  alto: [25, 40],
};

// ─── Pesos da engine de score ─────────────────────────────────────────────────

export const WEIGHTS = {
  /** Pontuação base antes de qualquer modificador */
  base: 30,

  /** Bonus por horário da semana */
  timeOfDay: [
    { hours: [7, 8],           bonus: 8  },  // manhã cedo
    { hours: [9, 10],          bonus: 12 },  // pico manhã
    { hours: [11, 12, 13],     bonus: 18 },  // almoço
    { hours: [14, 15, 16],     bonus: 8  },  // tarde
    { hours: [17, 18, 19],     bonus: 25 },  // pico noite (maior fluxo real)
    { hours: [20, 21],         bonus: 12 },  // noite
    { hours: [22, 23],         bonus: 5  },  // tarde da noite
    // horas 0-6 → bonus 0 (madrugada)
  ] as { hours: number[]; bonus: number }[],

  weekend: 20,
  holiday: 25,

  /** Efeito do pagamento: dias 1-5 do mês */
  beginningOfMonth: 10,

  /** Por tipo de mercado: bonus weekday / weekend */
  marketType: {
    atacado:      { weekday: 8,   weekend: 20  },  // explode aos sábados
    supermercado: { weekday: 0,   weekend: 5   },
    mercado:      { weekday: 0,   weekend: 0   },
    premium:      { weekday: -10, weekend: -5  },   // menos lotado
    convenience:  { weekday: -5,  weekend: -5  },
    discount:     { weekday: 12,  weekend: 15  },   // mercados populares
  } as Record<MarketType, { weekday: number; weekend: number }>,

  /** Por faixa de preço */
  priceLevel: {
    low:     15,   // mercados baratos → mais cheios
    medium:  0,
    high:    -10,
    premium: -15,
  } as Record<PriceLevel, number>,

  /**
   * Por tamanho: mercados menores parecem mais cheios com o mesmo tráfego;
   * mercados grandes suportam mais fluxo sem impacto na experiência.
   */
  size: {
    small:       12,
    medium:      0,
    large:       -8,
    extra_large: -15,
  } as Record<MarketSize, number>,
} as const;

// ─── Configuração de tendência ────────────────────────────────────────────────

/** Delta mínimo entre médias para considerar tendência direcional */
export const TREND_DELTA_THRESHOLD = 8;

/** Quantos snapshots recentes usar para calcular tendência */
export const TREND_WINDOW = 6;

// ─── Extensibilidade futura ───────────────────────────────────────────────────
// TODO: integrar feriados via API (ex: brasilapi.com.br/api/feriados/v1/:ano)
// TODO: integrar clima via OpenWeatherMap → bonus por chuva/frio (+10 indoors)
// TODO: integrar Google Places Popular Times
// TODO: bonus por eventos regionais (shows, jogos)
// TODO: modelo ML substituindo os pesos heurísticos
