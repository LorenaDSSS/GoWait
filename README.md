# GoWait — Documentação 

## Stack Tecnológico

### App Mobile

| Tecnologia | Versão | Uso |
|---|---|---|
| React Native | via Expo ~54 | Framework mobile (iOS + Android) |
| Expo | ~54 | Toolchain, build, OTA updates |
| TypeScript | — | Linguagem principal |

### Backend / Infraestrutura

| Tecnologia | Uso |
|---|---|
| **Supabase** (PostgreSQL gerenciado) | Banco de dados principal, autenticação, Realtime |
| **Supabase Edge Functions** (Deno) | Funções serverless: `weather-sync`, `location-snapshot`, `send-alert`, `holiday-sync` |
| **Supabase Realtime** | Push de atualizações de estado para o app via WebSocket |
| **pg_cron** (extensão PostgreSQL) | Agendamento de jobs recorrentes (snapshots, limpeza, alertas) |
| **pg_net** (extensão PostgreSQL) | Chamadas HTTP de dentro do Postgres → Edge Functions |
| **Deno** | Runtime das Edge Functions (substitui Node.js no ambiente Supabase) |
| **Git / GitHub** | Controle de versão — branches `main` (proteção) e `dev` (ativo) |

### APIs Externas

| API | Plano | Uso |
|---|---|---|
| **OpenWeatherMap** (`api.openweathermap.org`) | Free (1k req/dia) | Clima atual por coordenada — populado pela Edge Function `weather-sync` a cada 30 min para **12 municípios** do RJ |
| **Overpass API** (OpenStreetMap) | Gratuito | Busca de locais físicos (`shop=supermarket\|convenience\|wholesale`) para o importador `scripts/import-locations-rj.js` |
| **Nominatim** (OpenStreetMap) | Gratuito (1 req/s) | Geocodificação reversa — enriquece bairro e município dos locais importados |
| **Resend** (`api.resend.com`) | Free (3k emails/mês) | Envio de emails de alerta (`send-alert`) quando retenção atinge ATENÇÃO ou CRÍTICO |
| **BrasilAPI** (`brasilapi.com.br`) | Gratuito, sem chave | Feriados nacionais brasileiros — populado pela Edge Function `holiday-sync` anualmente |

### Ferramentas de Desenvolvimento

| Ferramenta | Uso |
|---|---|
| **Node.js** | Execução do script de importação (`scripts/import-locations-rj.js`) |
| **Supabase CLI** | Deploy de Edge Functions, gerenciamento local de migrations |
| **curl** | Testes manuais de Edge Functions |

### Secrets configurados

| Secret | Onde | Descrição |
|---|---|---|
| `OPENWEATHER_API_KEY` | Edge Function `weather-sync` | Chave da API OpenWeatherMap |
| `RESEND_API_KEY` | Edge Function `send-alert` | Chave da API Resend |
| `ALERT_EMAIL` | Edge Function `send-alert` | Email de destino dos alertas de capacidade |
| `service_role_key` | Tabela `_app_config` (banco) | Chave usada pelo `auto_adjust_retention()` para chamar `send-alert` via pg_net |

---

## Conceitos de Negócio

### Objetivo

O GoWait é um **sistema de apoio à decisão de deslocamento** baseado no fluxo de pessoas em locais físicos (mercados, farmácias, varejo, etc.). O usuário consulta o app antes de sair de casa para saber se vale a pena ir a um local naquele momento, evitando filas e desperdício de tempo.

**Princípio de desenvolvimento:** entregar **qualidade e métricas confiáveis** desde o início, com infraestrutura enxuta — usando muito pagando pouco. Toda a stack atual opera em planos gratuitos (Supabase Free, OpenWeatherMap Free, Resend Free), sem comprometer a confiabilidade dos dados ou a experiência do usuário.

**Escopo atual:**
- Cobertura geográfica: **Rio de Janeiro** (691 locais importados da Região Metropolitana via OpenStreetMap)
- Segmento de dados: **mercados** (supermercados, atacados, conveniências) — dados já estruturados e funcionando
- Expansão planejada: farmácias, restaurantes, bancos, serviços públicos e outros tipos de locais físicos com alta demanda de deslocamento

**Valor gerado:**
- Redução do tempo de espera percebido pelo usuário
- Melhor experiência de deslocamento urbano
- Dados de padrão de fluxo acumulados ao longo do tempo para análise de tendências por local, horário e tipo de segmento

**Áreas/usuários atendidos:**
- Usuário final (consumidor) via app móvel (iOS/Android — React Native/Expo)
- Operadores de locais (futura expansão para painel administrativo)

**Oportunidades de negócio:**
- Monetização via parcerias com redes de varejo (dados de demanda em tempo real)
- Publicidade contextual baseada em intenção de deslocamento
- API de fluxo para terceiros (supermercados, shoppings, farmácias)
- Expansão para novos segmentos: alimentação, serviços públicos, bancos, cartórios

---

## Disposição dos Dados

### Escopo

Os dados cobrem **locais físicos cadastrados manualmente** na tabela `locations`. O sistema opera em **4 camadas complementares**:

| Camada | Tabela | Natureza | Atualização |
|---|---|---|---|
| 🟢 Estado atual | `locations` | Heurística | A cada snapshot (15 min) |
| 🟡 Histórico de fluxo | `location_metrics` | Heurística | A cada snapshot (15 min) |
| 🔵 Comportamento humano | `location_user_signals` | Comportamental | Evento a evento (em tempo real) |
| 🟣 Inteligência adaptativa | `location_intelligence` | IA (dormante) | Gerado quando ≥ 200 sinais + ≥ 20 feedbacks por local |

### Recorte Temporal

- Snapshots gerados **a cada 15 minutos** via pg_cron ou Edge Function
- Retenção de **6 snapshots por local** (aproximadamente 1h30 de histórico ativo)
- Timezone de referência: **America/Sao_Paulo**

### Métricas

| Métrica | Tipo | Descrição |
|---|---|---|
| `crowd_score` | `int` (0–100) | Índice heurístico de intensidade de fluxo de pessoas |
| `flow` | `text` | Classificação legível: `baixo`, `médio`, `alto` |
| `wait_time` | `text` | Estimativa de espera formatada (ex: `"12 min"`) |
| `trend` | `text` | Direção do fluxo: `subindo`, `caindo`, `estável` |
| `is_weekend` | `bool` | Indica se o snapshot foi gerado em fim de semana |
| `is_holiday` | `bool` | Indica se é feriado — consultado em tempo real na tabela `holiday_cache` |
| `hour_of_day` | `int` | Hora local do snapshot (0–23, fuso São Paulo) |
| `day_of_week` | `int` | Dia da semana (0 = domingo, 6 = sábado) |

### Granularidade

- **Unidade mínima:** 1 snapshot por local por ciclo de 15 minutos
- **Chave de negócio:** `location_id` (UUID) + `created_at`

---

## Camada 3 — Sinais de Comportamento do Usuário

### Por que essa camada existe

As camadas 1 e 2 respondem: **"como está o local agora?"**

A Camada 3 responde: **"o que os usuários fazem com essa informação?"**

Essa distinção é fundamental. Um `crowd_score` de 65 (Ativo) pode ter comportamentos completamente diferentes:
- Usuários que abrem, visualizam 30 segundos e saem → sinal de que percebem como lotado
- Usuários que abrem e imediatamente navegam → sinal de que consideram aceitável

Com o acúmulo desses sinais, o sistema evolui de "estado atual" para "previsão de deslocamento inteligente".

### Tabela: `location_user_signals`

#### Eventos capturados

| Evento | `intent_score` | Quando é enviado |
|---|---|---|
| `search` | 20 | Usuário buscou e o local apareceu |
| `view` | 30 | Usuário abriu o dashboard do local |
| `dismiss` | 10 | Usuário fechou sem navegar (botão Voltar) |
| `click` | 60 | Usuário selecionou o local da lista |
| `return` | 75 | Reservado para retorno ao local após dismiss |
| `navigate` | 90 | Reservado para quando o usuário iniciar rota |
| `feedback` | 95 | Avaliação pós-visita — prova mais forte de que o usuário foi ao local |

#### Campos capturados por evento

| Campo | Tipo | Descrição |
|---|---|---|
| `location_id` | `uuid` | Referência ao local |
| `event_type` | `text` | Tipo do evento (tabela acima) |
| `intent_score` | `int` (0–100) | Score de intenção calculado no cliente |
| `dwell_time_seconds` | `int` | Tempo em segundos no dashboard (só para `view`) |
| `source` | `text` | Origem: `nearby`, `search`, `map`, `recommendation` |
| `flow_at_event` | `text` | Fluxo do local no momento da interação |
| `score_at_event` | `int` | `crowd_score` no momento da interação |
| `hour_of_day` | `int` | Hora local (fuso São Paulo) |
| `day_of_week` | `int` | Dia da semana |
| `is_weekend` | `bool` | Flag calculada no momento |
| `is_holiday` | `bool` | Flag de feriado |
| `created_at` | `timestamptz` | Timestamp do evento |

#### Implementação no app

Os sinais são enviados de forma **fire-and-forget** via `lib/signals.ts`. Nunca bloqueiam a UI. Falhas de rede são silenciosas intencionalmente.

Pontos de captura no app (`app/(tabs)/index.tsx`):

| Interação do usuário | Evento gerado | Source |
|---|---|---|
| Toca em local da lista "Próximos" | `click` | `nearby` |
| Toca em resultado da busca | `click` | `search` |
| Fecha o dashboard (botão Voltar) | `dismiss` | origem do clique anterior |
| Dashboard desmonta | `view` + `dwell_time_seconds` | origem do clique anterior |
| Responde banner de feedback pós-visita | `feedback` + `feedback_value` | `nearby` |

#### View analítica: `location_intent_summary`

Criada pela migration, agrega sinais por local + hora + dia da semana:

```sql
SELECT * FROM location_intent_summary
WHERE location_id = '<UUID>'
ORDER BY avg_intent DESC;
```

Retorna: `total_signals`, `avg_intent`, `dismissals`, `navigations`, `clicks`, `avg_dwell_seconds`

#### Casos de uso futuros com essa camada

| Insight | Como detectar |
|---|---|
| "Local percebido como cheio antes do sistema detectar" | Alta taxa de `dismiss` quando `flow = 'médio'` |
| "Melhor horário real para ir" | Hora com maior `avg_intent` e menor `dismissals` |
| "Usuários sensíveis a preço" | Alta taxa de `dismiss` em locais `price_level = high` |
| "Score heurístico subestima fluxo real" | Muitos `dismiss` com `score_at_event` baixo |
| "Janela de recomendação" | Hora com `navigate/click ratio` acima da média |

#### Retenção

Diferente de `location_metrics` (retém só 6 snapshots), os sinais têm **valor analítico acumulado** e são mantidos por **30 dias** (janela dinâmica — ver Governança de Dados). Um job pg_cron (`cleanup-signals`) roda diariamente às 03h e deleta registros além da janela ativa.

#### Feedback pós-visita (`hooks/use-visit-feedback.ts`)

Ao clicar em um local, o app salva a visita localmente via `AsyncStorage`. Quando o usuário reabre o app, o sistema verifica se há visita pendente elegível e exibe o banner `FeedbackBanner`:

**Critérios para exibir o banner (todos devem ser verdadeiros):**
- Tempo desde o clique ≥ 20 min e ≤ 3h
- Usuário está a ≤ 500m do local (usando coordenadas atuais)
- Feedback ainda não foi solicitado para essa visita

**Opções de resposta:** 😌 Tranquilo · 🙂 Moderado · 😬 Cheio · Não fui

"Não fui" descarta o banner sem registrar sinal — também é um dado valioso (usuário viu o score e decidiu não ir). As demais opções enviam um `feedback` event com `feedback_value` para `location_user_signals`, alimentando a Camada 4 (IA adaptativa).

---

## Regras Aplicadas

### Motor de Score (`calculateCrowdScore`)

O `crowd_score` é calculado de forma **puramente heurística**, sem coleta de dados reais de movimento. A pontuação final é a soma de variáveis contextuais com pesos pré-definidos, limitada ao intervalo [0, 100].

**Ponto de partida (base):** 30 pontos.

#### Modificadores aplicados em ordem:

| Variável | Condição | Impacto |
|---|---|---|
| `base_crowd_factor` | Fator estrutural do local (escala 0–100, neutro=50) | `(fator - 50) × 0.3` pts (range: -15 a +15) |
| Horário — manhã cedo | 07h–08h | +8 pts |
| Horário — manhã | 09h–10h | +12 pts |
| Horário — almoço | 11h–13h | +18 pts |
| Horário — tarde | 14h–16h | +8 pts |
| Horário — pico noturno | 17h–19h | **+25 pts** |
| Horário — noite | 20h–21h | +12 pts |
| Horário — tarde da noite | 22h–23h | +5 pts |
| Fim de semana | `dow in (0,6)` | +20 pts |
| Feriado | `is_holiday = true` | +25 pts |
| Início do mês (efeito salário) | `dom <= 5` | +10 pts |
| **Quinzena (efeito 2ª parcela)** | `dom between 13 and 16` | **+8 pts** |
| Segmento `atacado` | fim de semana | +20 pts; dia útil +8 pts |
| Segmento `supermercado` | fim de semana | +5 pts; dia útil 0 |
| Segmento `premium` | fim de semana | -5 pts; dia útil -10 pts |
| Segmento `convenience` | qualquer | -5 pts |
| Segmento `discount` | fim de semana | +15 pts; dia útil +12 pts |
| Nível de preço `low` | — | +15 pts |
| Nível de preço `high` | — | -10 pts |
| Nível de preço `premium` | — | -15 pts |
| Tamanho `small` | — | +12 pts |
| Tamanho `large` | — | -8 pts |
| Tamanho `extra_large` | — | -15 pts |

#### Picos horários por contexto urbano (`location_context`)

O bônus de pico (`+25 pts`) não é universal: o campo `location_context` define qual janela horária é o horário de pico real para cada tipo de local. Isso evita que um shopping seja pontuado como lotado às 07h (horário de pico de terminal).

| Contexto | Valor da coluna | Pico principal | Observações |
|---|---|---|---|
| Rua comercial | `comercial_street` | 11h–13h + 17h–18h | Fluxo de almoço e saída de trabalho |
| Standalone / bairro | `standalone` | 17h–19h | Padrão — equivale ao pico genérico |
| Residencial | `residential` | 17h–19h | +22 pts fim de semana |
| Shopping | `mall` | 14h–17h | +25 pts fim de semana |
| Terminal / hub | `transit_hub` | 07h–08h + 17h–19h | Dois picos — manhã e saída |

> **Nota:** `comercial_street` é grafado sem 'h' (CHECK constraint do banco).

#### Conversão score → flow

| Score | Flow | Label exibido |
|---|---|---|
| 0 – 55 | `baixo` | Tranquilo |
| 56 – 75 | `médio` | Moderado |
| 76 – 100 | `alto` | Cheio |

#### Conversão score → wait_time

O tempo de espera é calculado em duas etapas:

**Etapa 1 — base por interpolação linear:**

| Flow | Faixa de score | Faixa de espera base |
|---|---|---|
| `baixo` | 0 – 55 | 5 – 10 min |
| `médio` | 56 – 75 | 12 – 20 min |
| `alto` | 76 – 100 | 25 – 40 min |

**Etapa 2 — ajuste por número de caixas (`checkout_count`):**

O tempo base é multiplicado por um fator derivado da razão entre o número de referência de caixas para o porte do local e o número real de caixas cadastrado:

```
fator_caixas = referência[size] / checkout_count
               (limitado ao intervalo [0.4, 3.0])
```

| Porte | Referência de caixas |
|---|---|
| `small` | 2 |
| `medium` | 5 |
| `large` | 10 |
| `extra_large` | 18 |

Exemplo: local `extra_large` com 12 caixas → fator = 18/12 = 1.5. Um wait_time base de 20 min vira 30 min. Um local com mais caixas que a referência reduz o tempo estimado.

#### Cálculo de tendência (`computeTrend`) — preditivo

A tendência é **preditiva**, não retrospectiva. Em vez de comparar snapshots passados entre si, a função calcula o score que o local teria na **próxima hora** (usando os mesmos parâmetros estruturais) e compara com o score atual:

```
delta = score(hora_atual + 1h) − score(hora_atual)
```

- Delta > +5 → `subindo` (vai encher)
- Delta < -5 → `caindo` (vai esvaziar)
- Caso contrário → `estável`

Isso resolve o problema do modelo retrospectivo (que sempre ficava `estável` por falta de snapshots nas primeiras horas do dia) e torna a tendência útil desde o primeiro snapshot do local.

### Coluna `vertical`

Campo voltado ao usuário final que classifica o tipo de local de forma legível, independente do `segment` técnico usado no motor de score.

| Valor | Exemplos de locais |
|---|---|
| `mercado` | Supermercados, atacados, mercearias |
| `farmácia` | Farmácias e drogarias |
| `varejo` | Lojas de roupas, eletrônicos |
| `alimentação` | Restaurantes, lanchonetes |
| `serviços` | Bancos, cartórios |

---

## Conceitos Técnicos e Sustentação

### Arquitetura do Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                        Supabase                             │
│                                                             │
│  ┌──────────────┐   a cada 15 min   ┌───────────────────┐  │
│  │   pg_cron    │──────────────────▶│ run_location_     │  │
│  │  scheduler   │                   │ snapshot() [SQL]  │  │
│  └──────────────┘                   └────────┬──────────┘  │
│                                              │              │
│  ┌──────────────────────────┐               │              │
│  │  Edge Function           │               │              │
│  │  location-snapshot [Deno]│───────────────┤              │
│  │  (caminho preferido)     │               │              │
│  └──────────────────────────┘               ▼              │
│                                   ┌─────────────────────┐  │
│                                   │   locations         │  │
│                                   │   (estado atual)    │  │
│                                   └────────┬────────────┘  │
│                                            │  INSERT +      │
│                                            │  UPDATE        │
│                                            ▼                │
│                                   ┌─────────────────────┐  │
│                                   │  location_metrics   │  │
│                                   │  (histórico, 6 snaps│  │
│                                   │   por local)        │  │
│                                   └─────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Realtime (postgres_changes)                         │  │
│  │  Canal: "locations-live"  ▶  App React Native        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Fluxo resumido:**
1. Agendador dispara `run_location_snapshot()` (pg_cron) ou Edge Function a cada 15 min
2. Para cada local em `locations`: calcula `crowd_score`, `flow`, `wait_time`, `trend`
3. Atualiza campos de estado diretamente em `locations` (`crowd_score`, `flow`, `wait_time`, `trend`, `snapshot_at`)
4. Insere novo registro em `location_metrics` (histórico)
5. Deleta snapshots excedentes (mantém apenas os 6 mais recentes por local)
6. Supabase Realtime notifica o app mobile via WebSocket
7. App lê estado atual com **uma única query** em `locations` — sem JOIN com `location_metrics`

> **Decisão de arquitetura:** o app não consulta `location_metrics`. Todo o estado necessário para exibir a tela principal (`crowd_score`, `flow`, `wait_time`, `trend`, `snapshot_at`, `is_open`, `opening_hours`) está desnormalizado em `locations`. Isso elimina um round-trip ao banco e simplifica o código de enriquecimento de dados.

---

### Fontes de Dados

| Fonte | Tipo | Descrição |
|---|---|---|
| `locations` | Interna (Supabase PostgreSQL) | Cadastro de locais com atributos estruturais + estado atual |
| `location_metrics` | Interna (Supabase PostgreSQL) | Histórico de snapshots calculados (6 por local) |
| `location_user_signals` | Interna (Supabase PostgreSQL) | Sinais de comportamento do usuário (Camada 3) |
| `location_intelligence` | Interna (Supabase PostgreSQL) | IA adaptativa por local (Camada 4) — dormante |
| `weather_cache` | Interna (Supabase PostgreSQL) | Cache de clima por cidade — populado pela Edge Function `weather-sync` (12 municípios do RJ) |
| `holiday_cache` | Interna (Supabase PostgreSQL) | Cache de feriados nacionais — populado pela Edge Function `holiday-sync` via BrasilAPI (ano atual + próximo); 26 registros (2026+2027) |
| `retention_audit_log` | Interna (Supabase PostgreSQL) | Histórico de decisões do `auto_adjust_retention()` — rastreabilidade das mudanças de janela de retenção |
| `_app_config` | Interna (Supabase PostgreSQL) | Configurações internas restritas (ex: `service_role_key` para chamadas pg_net → Edge Functions) |
| OpenStreetMap (Overpass API) | Externa | Fonte primária de locais — importados via `scripts/import-locations-rj.js` |
| Nominatim (OSM Geocoding) | Externa | Geocodificação reversa para enriquecimento de bairro/município dos locais importados |
| BrasilAPI | Externa | Feriados nacionais brasileiros — consumida pela Edge Function `holiday-sync` |

---

### Responsáveis

| Recurso | Responsável atual |
|---|---|
| Codebase mobile (React Native/Expo) | Time GoWait |
| Supabase (banco, Edge Functions, Realtime) | Time GoWait |
| Cadastro de locais em `locations` | Importação via OSM (`scripts/import-locations-rj.js`) + ajustes manuais |
| Feriados (`holiday_cache`) | Edge Function `holiday-sync` via BrasilAPI — populada automaticamente todo ano em 1 jan |

---

### Jobs pg_cron ativos

| Job | Cron | Ação |
|---|---|---|
| `weather-sync` | `*/30 * * * *` | Sincroniza clima atual para os **12 municípios** da Região Metropolitana do RJ |
| `location-snapshot` | `*/15 * * * *` | Calcula e atualiza score de todos os locais |
| `aggregate-signals` | `0 */2 * * *` | Agrega sinais de comportamento por local |
| `refresh-intelligence` | `2 */2 * * *` | Atualiza `location_intelligence` com dados recentes |
| `calibrate-weights` | `0 6 * * *` | Recalibra pesos do motor de score |
| `cleanup-signals` | `0 3 * * *` | Deleta sinais além da janela de retenção ativa (30d / 15d / 7d — ajustada dinamicamente) |
| `cleanup-weather` | `0 4 * * 0` | Deleta entradas estagnadas de `weather_cache` (semanal) |
| `auto-adjust-retention` | `30 3 1,16 * *` | Avalia volume de `location_user_signals` e reajusta retenção automaticamente (dias 1 e 16 de cada mês) |
| `holiday-sync` | `0 6 1 1 *` | Atualiza `holiday_cache` com feriados do ano corrente + próximo via BrasilAPI (1 jan às 06h) |

```sql
-- Verificar jobs ativos
SELECT jobname, schedule, command FROM cron.job;
```

---

### Agendamento/Disparo

#### Caminho 1 — pg_cron (fallback SQL puro, roda dentro do Postgres)

```sql
SELECT cron.schedule(
  'location-snapshot',
  '*/15 * * * *',
  'SELECT run_location_snapshot()'
);
```

- Frequência: **a cada 15 minutos**
- Requisito: extensão `pg_cron` ativa no Supabase Dashboard > Database > Extensions
- Verificar jobs ativos: `SELECT * FROM cron.job;`

#### Caminho 2 — Edge Function Deno (caminho preferido para integrações)

- Nome da função: `location-snapshot`
- URL: `POST /functions/v1/location-snapshot`
- Disparada via Supabase Dashboard > Cron Jobs ou por webhook externo
- Vantagem: permite consumir APIs externas (feriados, clima) que o pg_cron não consegue

---

### Reprocessamento Manual

Para forçar um recálculo de snapshots sem aguardar o ciclo de 15 min:

#### Via SQL Editor (Supabase Dashboard):

```sql
SELECT run_location_snapshot();
```

#### Via curl (Edge Function):

```bash
curl -X POST https://<PROJECT_REF>.supabase.co/functions/v1/location-snapshot \
  -H "Authorization: Bearer <SUPABASE_ANON_KEY>"
```

Para limpar o histórico de um local específico e forçar recalculação zerada:

```sql
DELETE FROM location_metrics WHERE location_id = '<UUID_DO_LOCAL>';
SELECT run_location_snapshot();
```

> **Atenção:** deletar snapshots de um local remove o histórico de tendência. O campo `trend` voltará a retornar `estável` até que 4 novos snapshots sejam gerados (~1h).

---

### Bases de Dados

**Plataforma:** Supabase (PostgreSQL gerenciado)

#### Tabela: `locations`

Cadastro de locais. Todo o estado necessário para a tela principal do app está desnormalizado aqui — sem necessidade de JOIN.

| Coluna | Tipo | Descrição |
|---|---|---|
| `id` | `uuid` PK | Identificador único |
| `name` | `text` | Nome do local |
| `slug` | `text` | Identificador legível (ex: `mercado-central-rj`) |
| `segment` | `text` | Subcategoria técnica usada no motor de score (ex: `atacado`, `discount`) |
| `vertical` | `text` | Categoria visível ao usuário (ex: `mercado`, `farmácia`) |
| `size` | `text` | Porte do local: `small`, `medium`, `large`, `extra_large` |
| `price_level` | `text` | Faixa de preço: `low`, `medium`, `high`, `premium` |
| `base_crowd_factor` | `numeric` | Fator estrutural 0–100 (50 = neutro). Efeito: `(fator-50) × 0.3` pts |
| `location_context` | `text` | Contexto urbano: `standalone`, `residential`, `mall`, `comercial_street`, `transit_hub` |
| `checkout_count` | `int` | Número de caixas em operação normal (usado no cálculo de wait_time) |
| `opening_hours` | `jsonb` | Horários de funcionamento por dia: `{"mon": {"open": "08:00", "close": "22:00"}, ...}` |
| `is_open` | `bool` | Status calculado pelo pg_cron (pode ter atraso de até 15 min — app calcula localmente) |
| `latitude` | `numeric` | Coordenada geográfica |
| `longitude` | `numeric` | Coordenada geográfica |
| `city` | `text` | Localização: `"Bairro, Município - UF"` (ex: `"Catete, Rio de Janeiro - RJ"`) |
| `flow` | `text` | Estado atual: `baixo`, `médio`, `alto` |
| `wait_time` | `text` | Estimativa atual de espera |
| `trend` | `text` | Direção preditiva: `subindo`, `caindo`, `estável` |
| `crowd_score` | `int` | Score atual (0–100) — **blended**: baixa confiança = 100% heurístico; média = 75/25; alta = 50/50 IA |
| `snapshot_at` | `timestamptz` | Timestamp do último snapshot calculado |

> **Score blended:** `crowd_score` em `locations` é o score final exibido ao usuário, combinando heurística e IA conforme o `intelligence_score` disponível. O score heurístico puro (sem blend) fica em `location_metrics.crowd_score` para fins analíticos.

> **Abertura em tempo real:** o app **não** depende do campo `is_open` para determinar se um local está aberto. O status é calculado localmente pela função `getLocationStatus()` a partir de `opening_hours`, evitando o atraso de 15 min do pg_cron. O campo `is_open` é usado apenas como fallback quando `opening_hours` não está preenchido.

#### Tabela: `location_metrics`

Histórico de snapshots. Retém os **6 registros mais recentes por local** (janela deslizante de ~1h30). O número de linhas é **auto-limitado** em `N_locais × 6` — com 691 locais o teto é ~4.146 linhas (~3 MB), independentemente de quanto tempo o app estiver rodando.

| Coluna | Tipo | Descrição |
|---|---|---|
| `id` | `uuid` PK | Identificador do snapshot |
| `location_id` | `uuid` FK | Referência a `locations.id` |
| `slug` | `text` | Desnormalizado para facilitar queries de analytics |
| `vertical` | `text` | Desnormalizado para segmentação por categoria |
| `crowd_score` | `int` | Score calculado (0–100) |
| `flow` | `text` | Classificação no momento do snapshot |
| `wait_time` | `text` | Estimativa no momento do snapshot |
| `trend` | `text` | Tendência calculada no momento |
| `hour_of_day` | `int` | Hora local (fuso São Paulo) |
| `day_of_week` | `int` | Dia da semana (0=Dom, 6=Sáb) |
| `is_weekend` | `bool` | Flag calculada no momento |
| `is_holiday` | `bool` | Flag de feriado — populado via `holiday_cache` |
| `weather` | `text` | Reservado — ainda não populado |
| `created_at` | `timestamptz` | Timestamp automático do Supabase |

#### Tabela: `location_intelligence`

Armazena os parâmetros da camada de IA adaptativa por local. **Dormante** até que o volume mínimo de dados seja atingido.

| Coluna | Tipo | Descrição |
|---|---|---|
| `location_id` | `uuid` FK | Referência a `locations.id` |
| `intelligence_score` | `numeric` | Score calculado pela IA (substitui heurística quando disponível) |
| `model_version` | `text` | Versão do modelo gerado |
| `trained_at` | `timestamptz` | Último treinamento |
| `signal_count` | `int` | Número de sinais usados no treinamento |
| `feedback_count` | `int` | Número de feedbacks usados |

**Threshold de ativação por local:**
- `signal_count ≥ 200` sinais comportamentais
- `feedback_count ≥ 20` avaliações diretas

Enquanto dormante, `intelligence_score` é `NULL` e o app exibe o label `"Score"` (heurístico). Quando ativo, o label passa a `"IA"`. Nenhuma alteração de código necessária — o comportamento muda automaticamente pela presença ou ausência do valor.

---

#### Tabela: `location_user_signals`

Sinais de comportamento do usuário. Ver seção "Camada 3" acima para detalhes completos.

**Retenção dinâmica** — ajustada automaticamente pelo job `auto-adjust-retention` (dias 1 e 16 de cada mês):

| Volume de sinais | Janela de retenção | Status |
|---|---|---|
| < 100k linhas | 30 dias | OK |
| 100k – 300k linhas | 15 dias | ATENÇÃO |
| ≥ 300k linhas | 7 dias | CRÍTICO |

O job `cleanup-signals` roda diariamente às 03h e usa a janela configurada no momento. Cada decisão de ajuste é registrada em `retention_audit_log`. Se o status não for OK, um email de alerta é enviado automaticamente via Edge Function `send-alert` (Resend API).

**Índices criados:**
- `(location_id, created_at DESC)` — busca por local
- `(event_type, created_at DESC)` — análise por tipo
- `(hour_of_day, day_of_week)` — padrões temporais
- `(location_id, event_type, hour_of_day) WHERE event_type = 'dismiss'` — análise de abandono

---

#### Tabela: `weather_cache`

Cache de clima por cidade, populado pela Edge Function `weather-sync` a cada 30 minutos. Cobre os **12 municípios da Região Metropolitana do RJ**: Rio de Janeiro, Niterói, Duque de Caxias, Nova Iguaçu, São João de Meriti, Belford Roxo, Mesquita, Queimados, São Gonçalo, Seropédica, Itaguaí e Nilópolis. Usado pelo motor de score para ajustar o `crowd_score` conforme as condições climáticas.

| Coluna | Tipo | Descrição |
|---|---|---|
| `id` | `uuid` PK | Identificador único |
| `city` | `text` | Nome da cidade (ex: `"Rio de Janeiro"`) |
| `condition` | `text` | Condição atual: `clear`, `rain`, `drizzle`, `clouds`, `thunderstorm`, etc. |
| `temp_c` | `numeric` | Temperatura em °C |
| `feels_like_c` | `numeric` | Sensação térmica em °C |
| `humidity` | `int` | Umidade relativa (%) |
| `fetched_at` | `timestamptz` | Timestamp da última atualização |

**Impacto no score:** chuva/tempestade `+15 pts` (mais gente sai de casa para compras rápidas), calor extremo (>33°C) `+8 pts`. Registros desatualizados são limpos semanalmente pelo job `cleanup-weather`.

---

#### Tabela: `holiday_cache`

Cache de feriados nacionais brasileiros, populado pela Edge Function `holiday-sync` via **BrasilAPI** (sem necessidade de API key). Sempre mantém o ano corrente **e o ano seguinte**, garantindo que `location-snapshot` nunca consulte um feriado inexistente.

| Coluna | Tipo | Descrição |
|---|---|---|
| `date` | `date` PK | Data do feriado (ex: `2026-06-04`) |
| `name` | `text` | Nome do feriado (ex: `"Corpus Christi"`) |

**Estado atual:** 26 registros (13 feriados × 2 anos: 2026 + 2027).

**Cron:** `0 6 1 1 *` — roda em 1 jan às 06h, busca feriados do ano corrente + próximo, faz upsert. Auto-manutenível sem intervenção manual.

**Uso em `location-snapshot`:** a cada snapshot, a função consulta `holiday_cache` com a data atual (`.maybeSingle()`). Se encontrar registro, `is_holiday = true` → `+25 pts` no `crowd_score`.

---

### Particionamento/Clusterização

Não há particionamento formal configurado. Estratégia atual de retenção por aplicação:

```sql
-- Executado ao final de cada ciclo de run_location_snapshot()
DELETE FROM location_metrics
WHERE id NOT IN (
  SELECT id FROM (
    SELECT id, ROW_NUMBER() OVER (
      PARTITION BY location_id ORDER BY created_at DESC
    ) AS rn
    FROM location_metrics
  ) ranked
  WHERE rn <= 6
);
```

**Índices recomendados** (a criar conforme volume crescer):

```sql
CREATE INDEX IF NOT EXISTS idx_location_metrics_location_id
  ON location_metrics (location_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_locations_flow
  ON locations (flow);
```

---

### Governança de Dados e Alertas Automáticos

#### Orçamento de linhas (Supabase Free Tier: 500k total)

| Tabela | Volume esperado | Teto estimado |
|---|---|---|
| `location_user_signals` | escala com DAU | 300k (2k DAU × 5 sinais × 30d) |
| `location_metrics` | fixo | 4.146 (691 locais × 6 snapshots) |
| `locations` | fixo | ~700 |
| demais tabelas | fixo (upsert) | ~500 |

Para monitorar o consumo atual:

```sql
SELECT * FROM data_budget_audit();
```

Retorna para cada tabela: `total_linhas`, `limite_estimado`, `status` (OK / ATENÇÃO / CRÍTICO) e `acao_recomendada`.

#### Retenção dinâmica (`auto_adjust_retention`)

Função que roda automaticamente nos **dias 1 e 16 de cada mês às 03h30** via pg_cron. Avalia o volume de `location_user_signals` e reajusta a janela do job `cleanup-signals`:

| Volume | Janela | Status | Ação |
|---|---|---|---|
| < 100k | 30 dias | OK | Sem alteração |
| 100k – 300k | 15 dias | ATENÇÃO | Reduz retenção + envia email |
| ≥ 300k | 7 dias | CRÍTICO | Reduz retenção + envia email de urgência |

Cada decisão é registrada em `retention_audit_log` para rastreabilidade:

```sql
SELECT * FROM retention_audit_log ORDER BY checked_at DESC LIMIT 10;
```

Para invocar manualmente:

```sql
SELECT auto_adjust_retention();
```

#### Edge Function: `send-alert`

Chamada automaticamente pelo `auto_adjust_retention()` via **pg_net** (extensão HTTP do Postgres) quando o status não é OK. Envia email HTML formatado via **Resend API** (plano free: 3k emails/mês).

**Secrets necessários** (Dashboard → Edge Functions → `send-alert` → Secrets):

| Secret | Descrição |
|---|---|
| `RESEND_API_KEY` | Chave da API do Resend (`re_...`) |
| `ALERT_EMAIL` | Email de destino dos alertas |

**Testar manualmente:**

```bash
curl -X POST https://mfhienxxxaeyerjaoovx.supabase.co/functions/v1/send-alert \
  -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"status":"ATENÇÃO","signal_count":150000,"retention_days":15,"acao":"Teste manual"}'
```

#### Tabela `_app_config`

Armazena configurações internas restritas (acesso bloqueado para `public`, `anon` e `authenticated`). Usada para passar a `service_role_key` para funções `SECURITY DEFINER` que precisam chamar Edge Functions via pg_net.

```sql
-- Inserir após criar a tabela (Dashboard > Settings > API > service_role):
INSERT INTO _app_config (key, value)
VALUES ('service_role_key', '<SUA_SERVICE_ROLE_KEY>')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
```

---

### Script: `scripts/import-locations-rj.js`

Importa locais de varejo/mercado do **OpenStreetMap** via Overpass API para a tabela `locations`. Gera um arquivo SQL pronto para execução no Supabase SQL Editor.

**Área coberta:** município do Rio de Janeiro (bounding box `-23.08,-43.80,-22.74,-43.09`). Ajustar `BBOX` no script para outras cidades.

**Como executar:**

```bash
node scripts/import-locations-rj.js
# Gera: scripts/output/locations_rj.sql
# Executar o .sql gerado no Supabase Dashboard > SQL Editor
```

### Pipeline de importação

```
Overpass API  →  deduplicação  →  Nominatim geocoding  →  slug generation  →  SQL output
```

1. **Overpass API** — busca todos os nós/ways com `shop=supermarket|convenience|wholesale` na bbox. 5 endpoints de fallback em caso de rate limit.
2. **Cache de Overpass** — resultado salvo em `scripts/output/overpass_cache.json` (24h). Evita re-fetching desnecessário.
3. **Deduplicação** — remove locais com nome + coordenadas muito próximas (< 0,001°).
4. **Nominatim geocoding** — geocodificação reversa para obter bairro e município. Taxa: 1 req/s (respeito ao ToS do OSM). Cache em `scripts/output/nominatim_cache.json` (24h) com checkpoint a cada 50 registros.
5. **Enriquecimento de nome** — bairro sempre anexado ao nome se não constar: `"Guanabara"` + `"Realengo"` → `"Guanabara Realengo"`.
6. **City format** — `"Bairro, Município - UF"` (ex: `"Catete, Rio de Janeiro - RJ"`).
7. **Identificação de rede** — `NETWORK_MAP` (no script) associa padrões de nome a `segment`, `size`, `price_level` e `base_crowd_factor`.
8. **SQL gerado** — `INSERT INTO locations (...) VALUES ... ON CONFLICT (slug) DO NOTHING;`

### Redes mapeadas (`NETWORK_MAP`)

| Padrão | Segmento | Porte | Preço |
|---|---|---|---|
| Assaí, Atacadão, Makro | `atacado` | `extra_large` | `low` |
| Extra, Carrefour, Pão de Açúcar | `supermercado` | `large` | `medium` |
| Guanabara, Mondial, Mundial | `supermercado` | `large` | `medium` |
| Prezunic, Rede Economia, Vianense, Costazul | `discount` | `medium` | `low` |
| Natural da Terra, Hortifrúti, Zona Sul | `premium` | `medium` | `premium` |
| Farmácias (Drogasil, Ultrafarma, etc.) | `farmacia` | `small` | `medium` |
| Outros (sem padrão) | `supermercado` | `medium` | `medium` |

### Arquivos gerados (gitignored)

| Arquivo | Descrição |
|---|---|
| `scripts/output/overpass_cache.json` | Cache de 24h da resposta Overpass |
| `scripts/output/nominatim_cache.json` | Cache de 24h do geocoding Nominatim |
| `scripts/output/locations_rj.sql` | SQL gerado — **comitar se atualizado** |

### Estado atual

- **691 locais** importados para o banco (RJ — município)
- Horário padrão aplicado onde `opening_hours IS NULL`: seg-sab 07–22, dom 08–18, buffer 30 min

---

## Busca e UX

### Busca por local (`app/(tabs)/index.tsx`)

| Comportamento | Detalhe |
|---|---|
| Campos pesquisados | `name` e `city` (via `.or()` no Supabase) |
| Limite de resultados | 8 locais |
| Auto-seleção | Pressionar Enter/Buscar seleciona o primeiro resultado automaticamente |
| Resultado no dropdown | Uma linha: `"Nome Bairro, Município - UF"` (ex: `"Rede Economia Ingá, Niterói - RJ"`) |
| Scroll no dropdown | `ScrollView` com `maxHeight: 200`, `keyboardShouldPersistTaps="handled"` |

### Locais próximos (`nearby`)

| Parâmetro | Valor | Descrição |
|---|---|---|
| `NEARBY_RADIUS_KM` | `3.5` | Raio máximo em km para considerar um local "próximo" |
| `NEARBY_MAX` | `10` | Máximo de locais exibidos na lista |

Filtro aplicado via distância haversine — apenas locais dentro do raio são incluídos (não apenas os N mais próximos independentemente de distância).

### Exibição de cidade nos cards (`MarketRow`)

A função `formatCityLabel()` exibe somente `"Município - UF"` nos cards (omite o bairro), enquanto o dropdown da busca exibe a string completa `"Bairro, Município - UF"` para contexto adicional:

```ts
// "Catete, Rio de Janeiro - RJ"  →  "Rio de Janeiro - RJ"
function formatCityLabel(city: string | null | undefined): string | null {
  if (!city) return null;
  const comma = city.indexOf(",");
  return comma === -1 ? city : city.slice(comma + 1).trim();
}
```
