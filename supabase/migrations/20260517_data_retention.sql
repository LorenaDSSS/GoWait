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


-- ─── 0. Config para chamada da Edge Function via pg_net ─────────────────────
--
-- Guarda a service_role_key numa tabela restrita (sem RLS pública).
-- Execute manualmente após criar a tabela:
--   INSERT INTO _app_config (key, value)
--   VALUES ('service_role_key', '<SUA_SERVICE_ROLE_KEY>')
--   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
-- A chave está em: Dashboard > Settings > API > service_role (secret)

CREATE TABLE IF NOT EXISTS _app_config (
  key    text PRIMARY KEY,
  value  text NOT NULL
);

-- Bloqueia acesso público (só funções com SECURITY DEFINER podem ler)
REVOKE ALL ON _app_config FROM PUBLIC, anon, authenticated;


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


-- ─── 3. Tabela de log de auditoria + Função de auditoria manual ──────────────
--
-- Criada aqui (antes de data_budget_audit) pois a função já a referencia.

CREATE TABLE IF NOT EXISTS retention_audit_log (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  checked_at     timestamptz DEFAULT now(),
  signal_count   bigint,
  status         text,
  retention_days int,
  acao           text
);

-- Uso: SELECT * FROM data_budget_audit();
-- Retorna contagem atual de cada tabela para monitorar consumo de linhas.

-- DROP necessário pois adicionamos a coluna acao_recomendada (mudança de assinatura)
DROP FUNCTION IF EXISTS data_budget_audit();

CREATE OR REPLACE FUNCTION data_budget_audit()
RETURNS TABLE (
  tabela              text,
  total_linhas        bigint,
  limite_estimado     text,
  status              text,
  acao_recomendada    text
)
LANGUAGE sql STABLE
AS $$
  SELECT 'location_user_signals' AS tabela,
         COUNT(*) AS total_linhas,
         '300k (2k DAU × 5 sinais × 30d)' AS limite_estimado,
         CASE
           WHEN COUNT(*) < 100000 THEN 'OK'
           WHEN COUNT(*) < 300000 THEN 'ATENÇÃO'
           ELSE 'CRÍTICO'
         END AS status,
         CASE
           WHEN COUNT(*) < 100000 THEN '—'
           WHEN COUNT(*) < 300000 THEN 'Reduzir retenção de 30d → 15d no job cleanup-signals'
           ELSE 'Reduzir retenção para 7d OU fazer upgrade do plano Supabase'
         END AS acao_recomendada
  FROM location_user_signals

  UNION ALL

  SELECT 'location_metrics',
         COUNT(*),
         '4.146 (691 locais × 6 snapshots)',
         CASE WHEN COUNT(*) <= 5000 THEN 'OK' ELSE 'REVISAR' END,
         CASE WHEN COUNT(*) <= 5000 THEN '—'
              ELSE 'Verificar se o DELETE de janela deslizante está rodando em run_location_snapshot()'
         END
  FROM location_metrics

  UNION ALL

  SELECT 'locations',
         COUNT(*),
         '1.000 (expansão para outras cidades)',
         CASE WHEN COUNT(*) <= 1000 THEN 'OK' ELSE 'ATENÇÃO' END,
         CASE WHEN COUNT(*) <= 1000 THEN '—'
              ELSE 'Volume alto de locais — avaliar impacto no ciclo de snapshot (15 min)'
         END
  FROM locations

  UNION ALL

  SELECT 'location_intelligence', COUNT(*), '= nº de locais (691)', 'OK', '—'
  FROM location_intelligence

  UNION ALL

  SELECT 'location_signal_aggregate', COUNT(*), '= nº de locais (691)', 'OK', '—'
  FROM location_signal_aggregate

  UNION ALL

  SELECT 'weather_cache',
         COUNT(*),
         '12 (1 por município ativo)',
         CASE WHEN COUNT(*) <= 20 THEN 'OK' ELSE 'ATENÇÃO' END,
         CASE WHEN COUNT(*) <= 20 THEN '—'
              ELSE 'Verificar se o job cleanup-weather está ativo e removendo entradas obsoletas'
         END
  FROM weather_cache

  UNION ALL

  SELECT 'retention_audit_log',
         COUNT(*),
         'histórico de ajustes automáticos',
         'OK',
         COALESCE(
           (SELECT acao FROM retention_audit_log ORDER BY checked_at DESC LIMIT 1),
           'Nenhuma verificação executada ainda'
         )
  FROM retention_audit_log

  ORDER BY total_linhas DESC;
$$;

COMMENT ON FUNCTION data_budget_audit() IS
  'Auditoria do orçamento de linhas no free tier do Supabase. '
  'Execute SELECT * FROM data_budget_audit() para checar o consumo atual. '
  'Base: 691 locais importados do OSM (RJ). '
  'Sinais escalam com DAU (usuários ativos), não com número de locais. '
  'Plano de ação: ATENÇÃO → reduzir retenção 30d→15d; CRÍTICO → 7d ou upgrade.';


-- ─── 4. Ajuste automático de retenção ────────────────────────────────────────
--
-- Roda a cada 15 dias (1º e 16º de cada mês às 03h30).
-- Verifica o volume de location_user_signals e reajusta o job cleanup-signals
-- automaticamente conforme os thresholds. Registra cada decisão em
-- retention_audit_log para rastreabilidade.

CREATE OR REPLACE FUNCTION auto_adjust_retention()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER  -- necessário para ler _app_config (acesso bloqueado ao public)
AS $$
DECLARE
  v_count        bigint;
  v_retention    int;
  v_status       text;
  v_acao         text;
  v_service_key  text;
BEGIN
  SELECT COUNT(*) INTO v_count FROM location_user_signals;

  IF v_count >= 300000 THEN
    v_retention := 7;
    v_status    := 'CRÍTICO';
    v_acao      := 'Retenção reduzida para 7d — upgrade do Supabase recomendado';
  ELSIF v_count >= 100000 THEN
    v_retention := 15;
    v_status    := 'ATENÇÃO';
    v_acao      := 'Retenção reduzida para 15d';
  ELSE
    v_retention := 30;
    v_status    := 'OK';
    v_acao      := 'Sem alteração — retenção mantida em 30d';
  END IF;

  -- Reagenda o cleanup-signals com a nova janela
  PERFORM cron.unschedule('cleanup-signals');
  PERFORM cron.schedule(
    'cleanup-signals',
    '0 3 * * *',
    format(
      'DELETE FROM location_user_signals WHERE created_at < now() - interval ''%s days'';',
      v_retention
    )
  );

  -- Registra a decisão
  INSERT INTO retention_audit_log (signal_count, status, retention_days, acao)
  VALUES (v_count, v_status, v_retention, v_acao);

  -- Envia email de alerta se status não for OK
  IF v_status <> 'OK' THEN
    SELECT value INTO v_service_key FROM _app_config WHERE key = 'service_role_key';

    IF v_service_key IS NOT NULL THEN
      PERFORM net.http_post(
        url     := 'https://mfhienxxxaeyerjaoovx.supabase.co/functions/v1/send-alert',
        headers := jsonb_build_object(
          'Content-Type',  'application/json',
          'Authorization', 'Bearer ' || v_service_key
        ),
        body    := jsonb_build_object(
          'status',         v_status,
          'signal_count',   v_count,
          'retention_days', v_retention,
          'acao',           v_acao
        )
      );
    END IF;
  END IF;
END;
$$;

-- Roda nos dias 1 e 16 de cada mês às 03h30 (≈ a cada 15 dias)
SELECT cron.schedule(
  'auto-adjust-retention',
  '30 3 1,16 * *',
  'SELECT auto_adjust_retention()'
);
