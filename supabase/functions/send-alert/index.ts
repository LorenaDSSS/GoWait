// @ts-nocheck — arquivo Deno (Supabase Edge Function), não Node.js
/**
 * Supabase Edge Function: send-alert
 *
 * Envia email de alerta via Resend quando data_budget_audit detecta
 * status ATENÇÃO ou CRÍTICO.
 *
 * Secrets necessários (Dashboard > Edge Functions > Secrets):
 *   RESEND_API_KEY  — chave gratuita em https://resend.com (3k emails/mês)
 *   ALERT_EMAIL     — endereço de destino do alerta (ex: gowaitapp@gmail.com)
 *
 * Deploy:
 *   supabase functions deploy send-alert
 *
 * Payload esperado (POST JSON):
 *   {
 *     "status":       "ATENÇÃO" | "CRÍTICO",
 *     "signal_count": 123456,
 *     "retention_days": 15,
 *     "acao":         "Retenção reduzida para 15d"
 *   }
 */

function fmtNum(n: number): string {
  return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".");
}

Deno.serve(async (req: Request) => {
  try {
  const apiKey     = Deno.env.get("RESEND_API_KEY")?.trim();
  const alertEmail = Deno.env.get("ALERT_EMAIL")?.trim();

  if (!apiKey || !alertEmail) {
    return new Response(
      JSON.stringify({ error: "RESEND_API_KEY ou ALERT_EMAIL não configurado" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  let body: { status: string; signal_count: number; retention_days: number; acao: string };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Payload inválido" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const { status, signal_count, retention_days, acao } = body;
  const isoCritico = status === "CRÍTICO";
  const emoji      = isoCritico ? "🔴" : "🟡";
  const brt = new Date(Date.now() - 3 * 60 * 60 * 1000);
  const pad = (n: number) => n.toString().padStart(2, "0");
  const checkedAt  = `${pad(brt.getUTCDate())}/${pad(brt.getUTCMonth()+1)}/${brt.getUTCFullYear()} ${pad(brt.getUTCHours())}:${pad(brt.getUTCMinutes())}`;

  const htmlBody = `
    <h2 style="color:${isoCritico ? "#dc2626" : "#d97706"}">${emoji} GoWait — Alerta de capacidade: ${status}</h2>
    <p>Verificação automática de retenção executada em <strong>${checkedAt}</strong>.</p>
    <table style="border-collapse:collapse;width:100%;max-width:480px">
      <tr style="background:#f3f4f6">
        <td style="padding:8px 12px;font-weight:bold">Tabela</td>
        <td style="padding:8px 12px">location_user_signals</td>
      </tr>
      <tr>
        <td style="padding:8px 12px;font-weight:bold">Linhas atuais</td>
        <td style="padding:8px 12px">${fmtNum(signal_count)}</td>
      </tr>
      <tr style="background:#f3f4f6">
        <td style="padding:8px 12px;font-weight:bold">Status</td>
        <td style="padding:8px 12px;color:${isoCritico ? "#dc2626" : "#d97706"}"><strong>${status}</strong></td>
      </tr>
      <tr>
        <td style="padding:8px 12px;font-weight:bold">Retenção ajustada</td>
        <td style="padding:8px 12px">${retention_days} dias</td>
      </tr>
      <tr style="background:#f3f4f6">
        <td style="padding:8px 12px;font-weight:bold">Ação executada</td>
        <td style="padding:8px 12px">${acao}</td>
      </tr>
    </table>
    ${isoCritico
      ? `<p style="color:#dc2626;margin-top:16px"><strong>⚠️ Considere fazer upgrade do plano Supabase para evitar limitações.</strong></p>`
      : `<p style="margin-top:16px">A retenção foi reduzida automaticamente. Monitore o crescimento nas próximas semanas.</p>`
    }
    <hr style="margin-top:24px"/>
    <p style="color:#6b7280;font-size:12px">
      GoWait · Alerta automático via <code>auto_adjust_retention()</code><br/>
      Para consultar manualmente: <code>SELECT * FROM data_budget_audit();</code>
    </p>
  `;

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type":  "application/json",
    },
    body: JSON.stringify({
      from:    "GoWait Alerts <onboarding@resend.dev>",
      to:      [alertEmail],
      subject: `${emoji} GoWait — Alerta de capacidade: ${status} (${fmtNum(signal_count)} sinais)`,
      html:    htmlBody,
    }),
  });

  const data = await res.json();

  if (!res.ok) {
    return new Response(JSON.stringify({ error: "Falha ao enviar email", details: data }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ ok: true, email_id: data.id }), {
    headers: { "Content-Type": "application/json" },
  });

  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Erro interno", details: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
