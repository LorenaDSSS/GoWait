-- =============================================================================
-- GoWait — Horários de Funcionamento dos Locais
-- Migration: location_operating_hours
--
-- Motivação:
--   O sistema não deve gerar scores nem contabilizar sinais fora do horário
--   de funcionamento do local. Um score alto às 23h em um supermercado fechado
--   é um ruído que prejudica o modelo.
--
-- Regras de negócio implementadas:
--   1. Locais pequenos/médios (prezunic, conveniência, etc.)
--      → cutoff exato no horário de fechamento
--      → closing_buffer_minutes = 0
--
--   2. Atacados e mercados grandes (Guanabara, Extra, Assaí etc.)
--      → janela de 45 min após fechamento oficial
--      → Razão: clientes que entraram antes do fechamento ainda estão dentro
--      → closing_buffer_minutes = 45
--
--   3. Locais que fecham domingo ou dia específico
--      → chave do dia com { "closed": true }
--      → nenhum snapshot é gerado, nenhum sinal é contabilizado
--
-- Estrutura de opening_hours (JSONB):
--   Chaves: "mon","tue","wed","thu","fri","sat","sun","default"
--   "default" é o fallback para qualquer dia não listado explicitamente.
--   Cada chave tem: { "open": "HH:MM", "close": "HH:MM" }
--   Para dia fechado: { "closed": true }
--
--   Exemplos:
--     Abre todo dia igual:
--       {"default": {"open": "08:00", "close": "22:00"}}
--     Fecha domingo e tem horário diferente no sábado:
--       {
--         "default": {"open": "08:00", "close": "22:00"},
--         "sat":     {"open": "08:00", "close": "18:00"},
--         "sun":     {"closed": true}
--       }
-- =============================================================================


-- ─── 1. Adicionar colunas em locations ───────────────────────────────────────

ALTER TABLE locations
  ADD COLUMN IF NOT EXISTS opening_hours          jsonb,
  ADD COLUMN IF NOT EXISTS closing_buffer_minutes int NOT NULL DEFAULT 0;

-- Default conservador: aberto todo dia das 08h às 22h
UPDATE locations
SET opening_hours = '{"default": {"open": "08:00", "close": "22:00"}}'
WHERE opening_hours IS NULL;

-- Buffer de 45 min para atacados e mercados grandes
-- (clientes já dentro continuam sendo medidos após o fechamento oficial)
UPDATE locations
SET closing_buffer_minutes = 45
WHERE segment IN ('atacado')
   OR size    IN ('large', 'extra_large');

-- Comentário explicativo nos dados (não altera nada — serve de referência)
COMMENT ON COLUMN locations.opening_hours IS
  'Horários de funcionamento por dia da semana em JSONB.
   Chaves: mon|tue|wed|thu|fri|sat|sun|default.
   Valor: {"open":"HH:MM","close":"HH:MM"} ou {"closed":true}.
   "default" é o fallback para dias não listados.';

COMMENT ON COLUMN locations.closing_buffer_minutes IS
  'Minutos de janela após o fechamento oficial em que o local ainda é
   considerado ativo para fins de snapshot e coleta de sinais.
   0 = corte exato no fechamento (prezunic, lojas pequenas/médias).
   45 = atacado e mercados grandes (Guanabara, Extra, Assaí etc.)
        — clientes que entraram antes ainda estão sendo medidos.';


-- ─── 2. Função auxiliar: is_location_open() ──────────────────────────────────
-- Retorna TRUE se o local está operando no momento p_at (default: now()).
-- Consulta opening_hours + respeita closing_buffer_minutes.
--
-- Usada por:
--   • run_location_snapshot()  → pula locais fechados
--   • aggregate_location_signals() → filtra sinais fora do horário
--   • App (via location_hours_status view) → exibe status ao usuário

CREATE OR REPLACE FUNCTION is_location_open(
  p_location_id   uuid,
  p_at            timestamptz DEFAULT now()
) RETURNS boolean
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_hours         jsonb;
  v_buffer        int;
  v_now_br        timestamp;
  v_now_time      time;
  v_dow_key       text;
  v_day_hours     jsonb;
  v_open_time     time;
  v_close_time    time;
  v_close_plus    time;
BEGIN
  -- Busca configuração do local
  SELECT opening_hours, closing_buffer_minutes
  INTO v_hours, v_buffer
  FROM locations
  WHERE id = p_location_id;

  -- Local não encontrado ou sem horário → considera aberto (fail-open seguro)
  IF v_hours IS NULL THEN
    RETURN true;
  END IF;

  -- Hora atual no fuso Brasil
  v_now_br   := p_at AT TIME ZONE 'America/Sao_Paulo';
  v_now_time := v_now_br::time;

  -- Chave do dia da semana (0=sun via EXTRACT, mapeado para texto)
  v_dow_key := (ARRAY['sun','mon','tue','wed','thu','fri','sat'])
               [ EXTRACT(dow FROM v_now_br)::int + 1 ];

  -- Busca horário do dia específico, fallback para "default"
  v_day_hours := COALESCE(v_hours->v_dow_key, v_hours->'default');

  -- Sem entrada para este dia → considera aberto (operador não configurou)
  IF v_day_hours IS NULL THEN
    RETURN true;
  END IF;

  -- Dia marcado como fechado explicitamente
  IF (v_day_hours->>'closed')::boolean IS TRUE THEN
    RETURN false;
  END IF;

  -- Extrai open / close
  v_open_time  := (v_day_hours->>'open')::time;
  v_close_time := (v_day_hours->>'close')::time;

  -- Ainda não abriu
  IF v_now_time < v_open_time THEN
    RETURN false;
  END IF;

  -- Passou do fechamento + buffer → fechado
  v_close_plus := v_close_time + (COALESCE(v_buffer, 0) || ' minutes')::interval;
  IF v_now_time > v_close_plus THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;


-- ─── 3. Função: location_hours_status() ──────────────────────────────────────
-- Retorna status rico para consumo pelo app:
--   is_open           → bool
--   status            → 'open' | 'closing_soon' | 'closed'
--   closes_in_minutes → minutos até fechar (null se fechado ou longe)
--   opens_in_minutes  → minutos até abrir hoje (null se aberto ou fechou)
--   today_open        → "HH:MM"
--   today_close       → "HH:MM"
--
-- "closing_soon" = dentro da janela de buffer (atacado) OU ≤ 30min para fechar
-- O app usa isso para mostrar "Fecha em 45 min" quando relevante.

CREATE OR REPLACE FUNCTION location_hours_status(
  p_location_id uuid,
  p_at          timestamptz DEFAULT now()
) RETURNS TABLE (
  is_open           boolean,
  status            text,
  closes_in_minutes int,
  opens_in_minutes  int,
  today_open        text,
  today_close       text
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_hours         jsonb;
  v_buffer        int;
  v_now_br        timestamp;
  v_now_time      time;
  v_dow_key       text;
  v_day_hours     jsonb;
  v_open_time     time;
  v_close_time    time;
  v_open_bool     boolean;
  v_mins_to_close int;
  v_mins_to_open  int;
  v_status        text;
BEGIN
  SELECT opening_hours, closing_buffer_minutes
  INTO v_hours, v_buffer
  FROM locations WHERE id = p_location_id;

  IF v_hours IS NULL THEN
    RETURN QUERY SELECT true, 'open'::text, null::int, null::int, null::text, null::text;
    RETURN;
  END IF;

  v_now_br   := p_at AT TIME ZONE 'America/Sao_Paulo';
  v_now_time := v_now_br::time;
  v_dow_key  := (ARRAY['sun','mon','tue','wed','thu','fri','sat'])
                [ EXTRACT(dow FROM v_now_br)::int + 1 ];

  v_day_hours := COALESCE(v_hours->v_dow_key, v_hours->'default');

  -- Fechado hoje
  IF v_day_hours IS NULL OR (v_day_hours->>'closed')::boolean IS TRUE THEN
    RETURN QUERY SELECT false, 'closed'::text, null::int, null::int, null::text, null::text;
    RETURN;
  END IF;

  v_open_time  := (v_day_hours->>'open')::time;
  v_close_time := (v_day_hours->>'close')::time;
  v_open_bool  := is_location_open(p_location_id, p_at);

  -- Minutos até fechar (com buffer incluído)
  v_mins_to_close := EXTRACT(
    epoch FROM (v_close_time + (COALESCE(v_buffer, 0) || ' minutes')::interval - v_now_time)
  )::int / 60;

  -- Minutos até abrir (só relevante se fechado)
  IF v_now_time < v_open_time THEN
    v_mins_to_open := EXTRACT(epoch FROM (v_open_time - v_now_time))::int / 60;
  ELSE
    v_mins_to_open := null;
  END IF;

  -- Status: open | closing_soon | closed
  IF NOT v_open_bool THEN
    v_status := 'closed';
    v_mins_to_close := null;
  ELSIF v_mins_to_close <= GREATEST(30, COALESCE(v_buffer, 0)) THEN
    v_status := 'closing_soon';
  ELSE
    v_status := 'open';
    v_mins_to_close := null; -- não exibir se longe de fechar
  END IF;

  RETURN QUERY SELECT
    v_open_bool,
    v_status,
    v_mins_to_close,
    v_mins_to_open,
    TO_CHAR(v_open_time,  'HH24:MI'),
    TO_CHAR(v_close_time, 'HH24:MI');
END;
$$;


-- ─── 4. Recriar run_location_snapshot() com check de horário ─────────────────
-- Única mudança em relação à versão anterior:
--   • Pula locais fechados (is_location_open = false)
--   • Atualiza coluna is_open em locations a cada ciclo
-- Compatível com o pg_cron existente ('location-snapshot').

ALTER TABLE locations
  ADD COLUMN IF NOT EXISTS is_open boolean DEFAULT true;

CREATE OR REPLACE FUNCTION run_location_snapshot()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_location    RECORD;
  v_now         timestamp := now() AT TIME ZONE 'America/Sao_Paulo';
  v_hour        int  := EXTRACT(hour  FROM v_now)::int;
  v_dow         int  := EXTRACT(dow   FROM v_now)::int;
  v_dom         int  := EXTRACT(day   FROM v_now)::int;
  v_is_weekend  bool := v_dow IN (0, 6);
  v_is_holiday  bool := false;
  v_score       int;
  v_flow        text;
  v_wait        text;
  v_trend       text;
  v_open        bool;
BEGIN
  FOR v_location IN
    SELECT id, segment, price_level, size, base_crowd_factor, slug, vertical
    FROM locations
  LOOP
    v_open := is_location_open(v_location.id);

    -- Atualiza is_open independentemente (app mostra status correto)
    UPDATE locations SET is_open = v_open WHERE id = v_location.id;

    -- Pula snapshot se fechado — não polui location_metrics com dados inválidos
    CONTINUE WHEN NOT v_open;

    v_score := calculate_crowd_score(
      v_location.segment,
      v_location.price_level,
      v_location.size,
      v_location.base_crowd_factor,
      v_hour,
      v_is_weekend,
      v_is_holiday,
      v_dom
    );

    v_flow  := crowd_score_to_flow(v_score);
    v_wait  := crowd_score_to_wait_time(v_score);
    v_trend := compute_trend(v_location.id);

    INSERT INTO location_metrics (
      location_id, slug, vertical, crowd_score, flow, wait_time, trend,
      is_holiday, is_weekend, day_of_week, hour_of_day, weather
    ) VALUES (
      v_location.id, v_location.slug, v_location.vertical,
      v_score, v_flow, v_wait, v_trend,
      v_is_holiday, v_is_weekend, v_dow, v_hour, NULL
    );

    UPDATE locations
    SET flow      = v_flow,
        wait_time = v_wait,
        trend     = v_trend
    WHERE id = v_location.id;

  END LOOP;

  -- Manter apenas os 6 snapshots mais recentes por local (aberto ou fechado)
  DELETE FROM location_metrics
  WHERE id NOT IN (
    SELECT id FROM (
      SELECT id,
             ROW_NUMBER() OVER (PARTITION BY location_id ORDER BY created_at DESC) AS rn
      FROM location_metrics
    ) ranked
    WHERE rn <= 6
  );
END;
$$;


-- ─── 5. View: location_schedule (para admin / cadastro) ──────────────────────
-- Mostra o horário de cada local de forma legível com o status atual.

CREATE OR REPLACE VIEW location_schedule AS
SELECT
  l.id,
  l.name,
  l.vertical,
  l.segment,
  l.size,
  l.is_open,
  l.closing_buffer_minutes,
  hs.status,
  hs.closes_in_minutes,
  hs.opens_in_minutes,
  hs.today_open,
  hs.today_close,
  l.opening_hours
FROM locations l
CROSS JOIN LATERAL location_hours_status(l.id) hs
ORDER BY l.name;


-- ─── Notas de operação ────────────────────────────────────────────────────────
--
-- Para atualizar horário de um local específico:
--
--   UPDATE locations
--   SET opening_hours = '{
--     "default": {"open": "08:00", "close": "22:00"},
--     "sun":     {"open": "08:00", "close": "20:00"}
--   }'
--   WHERE name ILIKE '%guanabara%';
--
-- Para marcar local fechado às sextas:
--
--   UPDATE locations
--   SET opening_hours = opening_hours || '{"fri": {"closed": true}}'
--   WHERE id = '<uuid>';
--
-- Para verificar status atual de todos os locais:
--
--   SELECT name, is_open, status, closes_in_minutes, today_open, today_close
--   FROM location_schedule;
