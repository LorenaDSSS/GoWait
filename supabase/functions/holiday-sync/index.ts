// @ts-nocheck — arquivo Deno (Supabase Edge Function), não Node.js
/**
 * Supabase Edge Function: holiday-sync
 *
 * Responsabilidade:
 *   Buscar feriados nacionais do ano corrente e do próximo via BrasilAPI
 *   e popular a tabela `holiday_cache` no Supabase.
 *
 * Fonte: https://brasilapi.com.br/api/feriados/v1/{ano}
 *   - Gratuito, sem API key
 *   - Cobre apenas feriados nacionais brasileiros
 *
 * Scheduling:
 *   Cron: "0 6 1 1 *" — todo dia 1º de janeiro às 06h
 *   (popula ano corrente + próximo para cobrir virada)
 *
 * Deploy:
 *   supabase functions deploy holiday-sync
 *
 * Invoke manual (para popular agora):
 *   curl -X POST https://<ref>.supabase.co/functions/v1/holiday-sync \
 *     -H "Authorization: Bearer <SERVICE_ROLE_KEY>"
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async () => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const currentYear = new Date().getFullYear();
  const years       = [currentYear, currentYear + 1]; // popula este ano e o próximo

  const allHolidays: { date: string; name: string }[] = [];

  for (const year of years) {
    try {
      const res = await fetch(`https://brasilapi.com.br/api/feriados/v1/${year}`);
      if (!res.ok) {
        console.error(`BrasilAPI erro para ${year}: ${res.status}`);
        continue;
      }
      const data: { date: string; name: string; type: string }[] = await res.json();
      for (const h of data) {
        allHolidays.push({ date: h.date, name: h.name });
      }
    } catch (err) {
      console.error(`Falha ao buscar feriados de ${year}:`, err);
    }
  }

  if (allHolidays.length === 0) {
    return new Response(
      JSON.stringify({ error: "Nenhum feriado retornado pela BrasilAPI" }),
      { status: 502, headers: { "Content-Type": "application/json" } },
    );
  }

  // Upsert — mantém feriados existentes, adiciona/atualiza novos
  const { error } = await supabase
    .from("holiday_cache")
    .upsert(allHolidays, { onConflict: "date" });

  if (error) {
    return new Response(
      JSON.stringify({ error: "Falha ao salvar feriados", details: error.message }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  return new Response(
    JSON.stringify({ ok: true, synced: allHolidays.length, years }),
    { headers: { "Content-Type": "application/json" } },
  );
});
