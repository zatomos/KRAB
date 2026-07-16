// FCM (HTTP v1) transport.

import { JWT } from 'npm:google-auth-library@9';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

/** A push target as stored on a row of "Users". */
export interface PushSubscriptionRow {
  push_fcm_token: string | null;
}

interface SendResult {
  token: string;
  ok: boolean;
  gone: boolean;
}

export const PUSH_COLUMNS = 'push_fcm_token';

/**
 * True if this user has a usable push token.
 */
export function isReachable<T extends PushSubscriptionRow>(
  row: T | null | undefined
): row is T {
  return !!row?.push_fcm_token;
}

interface ServiceAccount {
  clientEmail: string;
  privateKey: string;
  projectId: string;
}

async function serviceAccountJson(): Promise<any | null> {
  try {
    const mod = await import('./service-account.json', {
      with: { type: 'json' },
    });
    if (mod.default) return mod.default;
  } catch {
    // Not deployed; fall through to the env var.
  }

  let raw = (Deno.env.get('FCM_SERVICE_ACCOUNT_JSON') ?? '').trim();
  // Some docker-compose versions leave the .env quotes on the value.
  if (
    raw.length >= 2 &&
    ((raw[0] === "'" && raw.at(-1) === "'") ||
      (raw[0] === '"' && raw.at(-1) === '"'))
  ) {
    raw = raw.slice(1, -1).trim();
  }
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch (e) {
    console.error('FCM_SERVICE_ACCOUNT_JSON is not valid JSON:', e);
    return null;
  }
}

/** The instance's FCM service account.*/
async function getServiceAccount(): Promise<ServiceAccount> {
  const parsed = await serviceAccountJson();
  if (!parsed) {
    throw new Error(
      'No service account: put it at _shared/service-account.json or set FCM_SERVICE_ACCOUNT_JSON',
    );
  }
  return {
    clientEmail: parsed.client_email,
    privateKey: parsed.private_key,
    projectId: parsed.project_id,
  };
}

/** Exchanges the service account for a short-lived FCM access token. */
function getAccessToken(sa: ServiceAccount): Promise<string> {
  const jwt = new JWT({
    email: sa.clientEmail,
    key: sa.privateKey,
    scopes: ['https://www.googleapis.com/auth/firebase.messaging'],
  });
  return new Promise((resolve, reject) => {
    jwt.authorize((err, tokens) => {
      if (err || !tokens?.access_token) {
        reject(err ?? new Error('no access token returned'));
        return;
      }
      resolve(tokens.access_token);
    });
  });
}

/**
 * Deliver to every token as a high-priority data message, and clear any token FCM reports
 as permanently gone.
 */
export async function sendPush(
  supabase: SupabaseClient,
  rows: Array<PushSubscriptionRow | null | undefined>,
  data: Record<string, string>
): Promise<void> {
  try {
    const tokens = [
      ...new Set(rows.filter(isReachable).map((r) => r.push_fcm_token!)),
    ];
    if (tokens.length === 0) return;

    const sa = await getServiceAccount();
    const accessToken = await getAccessToken(sa);
    const results = await sendToTokens(sa.projectId, accessToken, tokens, data);
    await pruneDeadTokens(supabase, results);
  } catch (e) {
    console.error('Push delivery failed:', e);
  }
}

const CHUNK_SIZE = 100;

/**
 * Sends the same payload to every token, concurrently and in chunks.
 */
async function sendToTokens(
  projectId: string,
  accessToken: string,
  tokens: string[],
  data: Record<string, string>
): Promise<SendResult[]> {
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  const results: SendResult[] = [];
  for (let i = 0; i < tokens.length; i += CHUNK_SIZE) {
    const chunk = tokens.slice(i, i + CHUNK_SIZE);
    const settled = await Promise.all(
      chunk.map((token) => sendOne(url, accessToken, token, data))
    );
    results.push(...settled);
  }
  return results;
}

async function sendOne(
  url: string,
  accessToken: string,
  token: string,
  data: Record<string, string>
): Promise<SendResult> {
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        message: {
          token,
          data,
          android: { priority: 'high', ttl: '43200s' },
        },
      }),
    });

    if (res.ok) return { token, ok: true, gone: false };

    // A token FCM no longer recognises comes back as 404 with an UNREGISTERED
    // error; treat those as gone so they get cleared, but keep everything else
    // so a working token is never dropped.
    const body = await res.text().catch(() => '');
    const gone = res.status === 404 || body.includes('UNREGISTERED');
    console.error(`FCM send failed (status ${res.status}):`, body);
    return { token, ok: false, gone };
  } catch (e) {
    console.error('FCM send threw:', e);
    return { token, ok: false, gone: false };
  }
}

/** Clears any token the push service flagged as permanently gone. */
export async function pruneDeadTokens(
  supabase: SupabaseClient,
  results: SendResult[]
): Promise<void> {
  const dead = [...new Set(results.filter((r) => r.gone).map((r) => r.token))];
  if (dead.length === 0) return;

  const { error } = await supabase
    .from('Users')
    .update({ push_fcm_token: null })
    .in('push_fcm_token', dead);

  if (error) {
    console.error('Failed to prune dead FCM tokens:', error.message);
  } else {
    console.log(`Pruned ${dead.length} dead FCM token(s)`);
  }
}
