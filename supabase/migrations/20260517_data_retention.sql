-- =============================================================================
-- GoWait — Política de retenção de dados
-- Migration: data_retention
--
-- Contexto:
--   Supabase free tier: ~500k linhas totais.
--   Com expansão no RJ (50–100 locais + crescimento de usuários), a tabela
--   location_user_signals é o único vetor de crescimento relevante.
--
-- Orçamento de linhas estimado (100 locais + 2k users/dia, janela 30d):
--   location_metrics        →    600  (6 por local, já blindado)
--   location_user_signals   → ~360k  (30d × 2k users × 3 events médios)
--   todas outras tabelas    →   ~500  (estáticas ou upsert)
--   TOTAL                   → ~361k  → margem confortável abaixo de 500k
--
-- O que esta migration faz:
--   1. Reduz retenção de signals de 90 → 30 dias
--      (após 30d, sinais brutos já foram agregados por aggregate-signals)
--   2. Atualiza o pg_cron cleanup-signals para a nova janela
--   3. Adiciona cleanup de weather_cache (remove cidades não monitoradas > 7d)
--   4. Cria função cleanup_stale_data() que pode ser chamada manualmente
--      para verificações pontuais
-- =============================================================================


-- ─── 1. Retenção de location_user_signals: 90d → 30d ─────────────────────────
--
-- Justificativa: o cron aggregate-signals (0 */2) compacta os sinais brutos
-- em location_signal_aggregate a cada 2h. Após 30 dias, os sinais brutos
-- perderam valor — a inteligência já absorveu o que precisava.
-- Os pesos calibrados ficam em location_model_weights (permanente).

SELECT cron.unschedule('cleanup-signals');

SELECT cron.schedule(
  'cleanup-signals',
  '0 3 * * *',   -- todo dia às 3h
  $$
    DELETE FROM location_user_signals
    WHERE created_at < now() - interval '30 days';
  $$
);


-- ─── 2. Cleanup de weather_cache: remove entradas > 7 dias ───────────────────
--
-- weather_cache usa PRIMARY KEY por cidade → apenas 1 linha por cidade monitorada.
-- O upsert mantém a tabela com N linhas (N = cidades ativas).
-- Este cleanup remove cidades que pararam de ser monitoradas há mais de 7 dias
-- (ex: cidade removida da Edge Function weather-sync por algum motivo).
-- Em operação normal, essa query não deleta nada — é uma rede de segurança.

SELECT cron.schedule(
  'cleanup-weather',
  '0 4 * * 0',   -- todo domingo às 4h
  $$
    DELETE FROM weather_cache
    WHERE updated_at < now() - interval '7 days';
  $$
);


-- ─── 3. Função de auditoria manual ───────────────────────────────────────────
--
-- Uso: SELECT * FROM data_budget_audit();
-- Retorna contagem atual de cada tabela para monitorar consumo de linhas.

CREATE OR REPLACE FUNCTION data_budget_audit()
RETURNS TABLE (
  tabela          text,
  total_linhas    bigint,
  limite_estimado text,
  status          text
)
LANGUAGE sql STABLE
AS $$
  SELECT 'location_user_signals' AS tabela,
         COUNT(*) AS total_linhas,
         '360k (100 locais, 2k users/dia, 30d)' AS limite_estimado,
         CASE
           WHEN COUNT(*) < 100000 THEN 'OK'
           WHEN COUNT(*) < 300000 THEN 'ATENÇÃO'
           ELSE 'CRÍTICO'
         END AS status
  FROM location_user_signals

  UNION ALL

  SELECT 'location_metrics',
         COUNT(*),
         '600 (100 locais × 6 snapshots)',
         CASE WHEN COUNT(*) < 1000 THEN 'OK' ELSE 'REVISAR' END
  FROM location_metrics

  UNION ALL

  SELECT 'locations',       COUNT(*), '500 (crescimento de locais)', 'OK'
  FROM locations

  UNION ALL

  SELECT 'location_intelligence', COUNT(*), '= nº de locais', 'OK'
  FROM location_intelligence

  UNION ALL

  SELECT 'location_signal_aggregate', COUNT(*), '= nº de locais', 'OK'
  FROM location_signal_aggregate

  UNION ALL

  SELECT 'weather_cache',   COUNT(*), '1 por cidade ativa', 'OK'
  FROM weather_cache

  ORDER BY total_linhas DESC;
$$;

COMMENT ON FUNCTION data_budget_audit() IS
  'Auditoria do orçamento de linhas no free tier do Supabase. '
  'Execute SELECT * FROM data_budget_audit() para checar o consumo atual. '
  'Alerta: ATENÇÃO em location_user_signals acima de 100k, CRÍTICO acima de 300k.';
