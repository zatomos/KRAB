// Shared FCM helpers for the notification edge functions.
//
//These helpers send the requests concurrently (in bounded chunks)
//and surface per-token results so callers can prune tokens FCM reports as permanently dead.

import { JWT } from 'npm:google-auth-library@9';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

export interface FcmResult {
  token: string;
  ok: boolean;
  /** FCM reported this token as permanently invalid; it should be removed. */
  unregistered: boolean;
}

/** Mints a short-lived FCM access token and returns it with the project id. */
export async function getFcmAccessToken(): Promise<{
  accessToken: string;
  projectId: string;
}> {
  const serviceAccount = JSON.parse(Deno.env.get('GOOGLE_SERVICE_ACCOUNT')!);
  const accessToken = await new Promise<string>((resolve, reject) => {
    const jwtClient = new JWT({
      email: serviceAccount.client_email,
      key: serviceAccount.private_key,
      scopes: ['https://www.googleapis.com/auth/firebase.messaging'],
    });
    jwtClient.authorize((err, tokens) => {
      if (err) reject(err);
      else resolve(tokens!.access_token);
    });
  });
  return { accessToken, projectId: serviceAccount.project_id as string };
}

const FCM_CHUNK_SIZE = 500;

/**
 * Sends the same data payload to every token concurrently, in chunks of
 * {@link FCM_CHUNK_SIZE}, and returns a result per token. Empty/falsy tokens are
 * skipped. Never throws: a failed send becomes a non-ok result.
 */
export async function sendToTokens(
  projectId: string,
  accessToken: string,
  tokens: Array<string | null | undefined>,
  data: Record<string, string>,
): Promise<FcmResult[]> {
  const valid = tokens.filter((t): t is string => !!t);
  const results: FcmResult[] = [];
  for (let i = 0; i < valid.length; i += FCM_CHUNK_SIZE) {
    const chunk = valid.slice(i, i + FCM_CHUNK_SIZE);
    const settled = await Promise.all(
      chunk.map((token) => sendOne(projectId, accessToken, token, data))
    );
    results.push(...settled);
  }
  return results;
}

async function sendOne(
  projectId: string,
  accessToken: string,
  token: string,
  data: Record<string, string>
): Promise<FcmResult> {
  try {
    const res = await fetch(
      `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${accessToken}`,
        },
        body: JSON.stringify({
          message: { token, android: { priority: 'HIGH' }, data },
        }),
      }
    );

    if (res.ok) return { token, ok: true, unregistered: false };

    const body = await res.json().catch(() => null);
    const errorCode = body?.error?.details?.find(
      (d: { errorCode?: string }) => typeof d?.errorCode === 'string'
    )?.errorCode;
    // A 404 / UNREGISTERED token will never be valid again; flag it for pruning.
    const unregistered = res.status === 404 || errorCode === 'UNREGISTERED';
    console.error(
      `FCM send failed (status ${res.status}, code ${errorCode ?? 'n/a'})`
    );
    return { token, ok: false, unregistered };
  } catch (e) {
    console.error('FCM send threw:', e);
    return { token, ok: false, unregistered: false };
  }
}

/** Nulls out any token FCM flagged as permanently invalid. */
export async function pruneDeadTokens(
  supabase: SupabaseClient,
  results: FcmResult[]
): Promise<void> {
  const dead = [
    ...new Set(results.filter((r) => r.unregistered).map((r) => r.token)),
  ];
  if (dead.length === 0) return;

  const { error } = await supabase
    .from('Users')
    .update({ fcm_token: null })
    .in('fcm_token', dead);
  if (error) {
    console.error('Failed to prune dead FCM tokens:', error.message);
  } else {
    console.log(`Pruned ${dead.length} dead FCM token(s)`);
  }
}
