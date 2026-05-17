-- =============================================================================
-- GoWait — Tabela de cache de feriados nacionais
-- Migration: holiday_cache
--
-- Fonte: BrasilAPI (https://brasilapi.com.br/api/feriados/v1/{ano})
--   - Gratuito, sem API key, mantido pela comunidade open-source
--   - Cobre apenas feriados nacionais brasileiros
--   - Populado pela Edge Function `holiday-sync` (cron: 1 jan às 06h)
--
-- Impacto no score: +25 pts quando is_holiday = true
-- (mesmo peso de fim de semana — feriados nacionais têm padrão de fluxo elevado)
-- =============================================================================

CREATE TABLE IF NOT EXISTS holiday_cache (
  date  date PRIMARY KEY,
  name  text NOT NULL
);

-- Acesso de leitura para a service_role (Edge Functions)
-- Sem RLS pública — leitura via SUPABASE_SERVICE_ROLE_KEY nas Edge Functions

COMMENT ON TABLE holiday_cache IS
  'Cache de feriados nacionais brasileiros. '
  'Populado pela Edge Function holiday-sync (BrasilAPI). '
  'Consultado pelo location-snapshot para setar is_holiday = true.';
