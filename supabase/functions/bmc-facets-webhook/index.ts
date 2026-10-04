import { createClient } from 'npm:@supabase/supabase-js@2';

const encoder = new TextEncoder();
const json = (body: unknown, status = 200) => Response.json(body, { status });

function constantTimeEqual(left: string, right: string) {
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let i = 0; i < left.length; i += 1) mismatch |= left.charCodeAt(i) ^ right.charCodeAt(i);
  return mismatch === 0;
}

async function expectedSignature(rawBody: string, secret: string) {
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(rawBody));
  return Array.from(new Uint8Array(signature), byte => byte.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async request => {
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const secret = Deno.env.get('BMC_WEBHOOK_SECRET');
  const signature = request.headers.get('x-signature-sha256')?.trim().toLowerCase();
  if (!secret || !signature) return json({ error: 'webhook_not_configured' }, 503);

  const rawBody = await request.text();
  const expected = await expectedSignature(rawBody, secret);
  if (!constantTimeEqual(expected, signature)) return json({ error: 'invalid_signature' }, 401);

  let event: Record<string, unknown>;
  try { event = JSON.parse(rawBody); }
  catch { return json({ error: 'invalid_json' }, 400); }

  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !serviceKey) return json({ error: 'server_not_configured' }, 503);
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const extras = Array.isArray((event.data as { extras?: unknown[] } | undefined)?.extras) ? (event.data as { extras: unknown[] }).extras : [];
  const answers = extras.flatMap(extra => Array.isArray((extra as { question_answers?: unknown[] })?.question_answers) ? (extra as { question_answers: unknown[] }).question_answers : []);
  const claimCode = answers.find(answer => typeof answer === 'string' && /^GI-[A-F0-9]{8}-[A-F0-9]{4}$/i.test(answer.trim()));
  let claim: { id: string; player_id: string } | null = null;
  const transactionId = String((event.data as { transaction_id?: unknown } | undefined)?.transaction_id ?? '');
  if (event.type === 'extra_purchase.created' && typeof claimCode === 'string') {
    const result = await admin.from('facet_claim_codes').update({ consumed_at: new Date().toISOString(), consumed_transaction_id: transactionId }).eq('code',claimCode.trim().toUpperCase()).is('consumed_at',null).gt('expires_at',new Date().toISOString()).select('id,player_id').maybeSingle();
    if (result.error) return json({ error: 'claim_lookup_failed' }, 500);
    claim = result.data;
  }
  const { data, error } = await admin.rpc('process_bmc_facet_event', { p_event: event, p_claim_id: claim?.id ?? null, p_player_id: claim?.player_id ?? null });
  if (error) {
    if (claim) await admin.from('facet_claim_codes').update({ consumed_at: null, consumed_transaction_id: null }).eq('id',claim.id).eq('consumed_transaction_id',transactionId);
    console.error('BMC Facet event rejected', { eventId: event.event_id, type: event.type, message: error.message });
    return json({ error: 'event_rejected', message: error.message }, 422);
  }
  return json({ ok: true, result: data });
});
