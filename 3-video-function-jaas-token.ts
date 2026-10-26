// ════════════════════════════════════════════════════════════════════
//  Supabase Edge Function: jaas-token
//  Gives a signed-in classroom user a short-lived pass (JWT) for the
//  JaaS (8x8) video call. The tutor joins as moderator.
//
//  Needs three Edge Function Secrets (Supabase → Edge Functions → Secrets):
//    JAAS_APP_ID       your App ID (starts with vpaas-magic-cookie-)
//    JAAS_KEY_ID       the API key's Key ID from the JaaS console
//    JAAS_PRIVATE_KEY  the whole contents of the private key file you downloaded
//
//  Turn OFF "Enforce JWT verification" (Verify JWT) for this function:
//  it checks the user's sign-in itself, below.
// ════════════════════════════════════════════════════════════════════

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

// ───────────── base64 helpers
function b64urlFromBytes(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
const b64urlFromString = (str: string) => b64urlFromBytes(new TextEncoder().encode(str));
function bytesFromB64(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// ───────────── private key parsing (accepts PKCS#8 "PRIVATE KEY" or PKCS#1 "RSA PRIVATE KEY")
function derLength(n: number): Uint8Array {
  if (n < 0x80) return new Uint8Array([n]);
  const bytes: number[] = [];
  while (n > 0) { bytes.unshift(n & 0xff); n >>= 8; }
  return new Uint8Array([0x80 | bytes.length, ...bytes]);
}
function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((a, p) => a + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}
const RSA_OID_SEQ = new Uint8Array([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]);

function pkcs1ToPkcs8(pkcs1: Uint8Array): Uint8Array {
  const version = new Uint8Array([0x02, 0x01, 0x00]);
  const octet = concat(new Uint8Array([0x04]), derLength(pkcs1.length), pkcs1);
  const body = concat(version, RSA_OID_SEQ, octet);
  return concat(new Uint8Array([0x30]), derLength(body.length), body);
}

function containsRsaOid(der: Uint8Array): boolean {
  const oid = RSA_OID_SEQ.slice(4, 13);
  outer: for (let i = 0; i < Math.min(der.length - oid.length, 64); i++) {
    for (let j = 0; j < oid.length; j++) if (der[i + j] !== oid[j]) continue outer;
    return true;
  }
  return false;
}

export function pemToPkcs8(pemRaw: string): Uint8Array {
  // Secrets pasted into a dashboard sometimes arrive with literal "\n" or with lost line breaks.
  const pem = pemRaw.replace(/\\n/g, '\n').trim();
  const isPkcs1 = /BEGIN RSA PRIVATE KEY/.test(pem);
  const b64 = pem.replace(/-----BEGIN [^-]+-----/g, '').replace(/-----END [^-]+-----/g, '').replace(/[^A-Za-z0-9+/=]/g, '');
  if (!b64) throw new Error('JAAS_PRIVATE_KEY is empty or not a private key.');
  const der = bytesFromB64(b64);
  if (isPkcs1 || !containsRsaOid(der)) return pkcs1ToPkcs8(der);
  return der;
}

export async function signJaasJwt(opts: {
  appId: string; keyId: string; privateKeyPem: string;
  user: { id: string; name: string; email?: string; moderator: boolean };
  now?: number; ttlSeconds?: number;
}): Promise<string> {
  const now = opts.now ?? Math.floor(Date.now() / 1000);
  const appId = opts.appId.trim();
  const keyId = opts.keyId.trim();
  const kid = keyId.includes('/') ? keyId : `${appId}/${keyId}`;
  const header = { alg: 'RS256', typ: 'JWT', kid };
  const payload = {
    aud: 'jitsi', iss: 'chat', sub: appId, room: '*',
    iat: now, nbf: now - 30, exp: now + (opts.ttlSeconds ?? 4 * 3600),
    context: {
      user: {
        id: opts.user.id, name: opts.user.name, email: opts.user.email || '', avatar: '',
        moderator: opts.user.moderator ? 'true' : 'false',
      },
      features: { livestreaming: 'false', recording: 'false', transcription: 'false', 'outbound-call': 'false' },
    },
  };
  const input = `${b64urlFromString(JSON.stringify(header))}.${b64urlFromString(JSON.stringify(payload))}`;
  const key = await crypto.subtle.importKey('pkcs8', pemToPkcs8(opts.privateKeyPem), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(input)));
  return `${input}.${b64urlFromBytes(sig)}`;
}

export async function handle(req: Request, env: (k: string) => string | undefined, fetcher: typeof fetch = fetch): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const appId = env('JAAS_APP_ID'), keyId = env('JAAS_KEY_ID'), pem = env('JAAS_PRIVATE_KEY');
    if (!appId || !keyId || !pem) {
      return json({ error: 'Video is not set up yet: add JAAS_APP_ID, JAAS_KEY_ID and JAAS_PRIVATE_KEY in Supabase → Edge Functions → Secrets.' }, 500);
    }
    const url = (env('SUPABASE_URL') || '').replace(/\/+$/, '');
    const auth = req.headers.get('Authorization') || '';
    const apikey = req.headers.get('apikey') || env('SUPABASE_ANON_KEY') || '';
    if (!auth.startsWith('Bearer ')) return json({ error: 'Please sign in again.' }, 401);

    const userRes = await fetcher(`${url}/auth/v1/user`, { headers: { Authorization: auth, apikey } });
    if (!userRes.ok) return json({ error: 'Your sign-in has expired. Please sign in again.' }, 401);
    const user = await userRes.json();

    const profRes = await fetcher(`${url}/rest/v1/profiles?select=full_name,role&id=eq.${encodeURIComponent(user.id)}`, {
      headers: { Authorization: auth, apikey, Accept: 'application/json' },
    });
    const rows = profRes.ok ? await profRes.json() : [];
    const profile = Array.isArray(rows) ? rows[0] : null;
    if (!profile) return json({ error: 'Your classroom account is not set up yet (no profile). Run setup.sql.' }, 403);

    const token = await signJaasJwt({
      appId, keyId, privateKeyPem: pem,
      user: { id: user.id, name: profile.full_name || user.email, email: user.email, moderator: profile.role === 'tutor' },
    });
    return json({ token, appId: appId.trim(), moderator: profile.role === 'tutor' });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const hint = /pkcs8|import|DataError|key/i.test(msg) ? 'Check that JAAS_PRIVATE_KEY contains the whole private key file, including the BEGIN and END lines.' : '';
    const sep = /[.!?]$/.test(msg) ? ' ' : '. ';
    return json({ error: 'Could not create the video pass: ' + msg + (hint ? sep + hint : '') }, 500);
  }
}

// deno-lint-ignore no-explicit-any
const D = (globalThis as any).Deno;
if (D?.serve) D.serve((req: Request) => handle(req, (k) => D.env.get(k)));
