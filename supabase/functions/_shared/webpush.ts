// Web Push transport.
//
// Payloads are encrypted to each subscriber's own key, so a push service sees
// only ciphertext, its own endpoint, and the timing.

import webpush from 'npm:web-push@3.6.7';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

/** A Web Push subscription as stored on a row of "Users". */
export interface PushSubscriptionRow {
  push_endpoint: string | null;
  push_p256dh: string | null;
  push_auth: string | null;
}

export interface PushResult {
  endpoint: string;
  ok: boolean;
  gone: boolean;
}

export interface VapidDetails {
  subject: string;
  publicKey: string;
  privateKey: string;
}

/** The columns a notification function must select to reach a user. */
export const PUSH_COLUMNS = 'push_endpoint, push_p256dh, push_auth';

/**
 * True if this user has a usable subscription. Generic so that narrowing a row
 * keeps whatever else was selected alongside the push columns.
 */
export function isReachable<T extends PushSubscriptionRow>(
  row: T | null | undefined
): row is T {
  return !!row?.push_endpoint && !!row.push_p256dh && !!row.push_auth;
}

/**
 * The single entry point the notification functions use: encrypt [data] to
 * every subscription in [rows], send it, and clear any the push service reports
 * as gone.
 *
 * Never throws. A missing keypair is logged rather than turned into a 500 that
 * the database webhook would keep retrying.
 */
export async function sendPush(
  supabase: SupabaseClient,
  rows: Array<PushSubscriptionRow | null | undefined>,
  data: Record<string, string>
): Promise<void> {
  try {
    const results = await sendToSubscriptions(getVapidDetails(), rows, data);
    await pruneDeadSubscriptions(supabase, results);
  } catch (e) {
    console.error('Push delivery failed:', e);
  }
}

/**
 * This instance's VAPID keypair.
 */
export function getVapidDetails(): VapidDetails {
  const publicKey = Deno.env.get('VAPID_PUBLIC_KEY');
  const privateKey = Deno.env.get('VAPID_PRIVATE_KEY');

  if (!publicKey || !privateKey) {
    throw new Error(
      'VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY are not set; run setup_backend.sh to generate a keypair'
    );
  }

  return {
    subject: Deno.env.get('VAPID_SUBJECT') ?? 'mailto:admin@localhost',
    publicKey,
    privateKey,
  };
}

const CHUNK_SIZE = 100;

/**
 * Sends the same payload to every subscription, concurrently and in chunks.
 * Rows without a complete subscription are skipped.
 */
export async function sendToSubscriptions(
  vapid: VapidDetails,
  rows: Array<PushSubscriptionRow | null | undefined>,
  data: Record<string, string>
): Promise<PushResult[]> {
  const body = JSON.stringify(data);

  const subs = rows.filter(
    (r): r is PushSubscriptionRow & { push_endpoint: string } =>
      !!r?.push_endpoint && !!r.push_p256dh && !!r.push_auth
  );

  const results: PushResult[] = [];
  for (let i = 0; i < subs.length; i += CHUNK_SIZE) {
    const chunk = subs.slice(i, i + CHUNK_SIZE);
    const settled = await Promise.all(
      chunk.map((row) => sendOne(vapid, row, body))
    );
    results.push(...settled);
  }
  return results;
}

async function sendOne(
  vapid: VapidDetails,
  row: PushSubscriptionRow & { push_endpoint: string },
  body: string
): Promise<PushResult> {
  const endpoint = row.push_endpoint;

  try {
    const details = webpush.generateRequestDetails(
      {
        endpoint,
        keys: { p256dh: row.push_p256dh!, auth: row.push_auth! },
      },
      body,
      {
        contentEncoding: 'aes128gcm',
        urgency: 'high',
        TTL: 12 * 60 * 60,
        vapidDetails: vapid,
      }
    );

    const res = await fetch(details.endpoint, {
      method: 'POST',
      headers: details.headers as HeadersInit,
      body: details.body as BodyInit,
    });

    if (res.ok) return { endpoint, ok: true, gone: false };

    const gone = res.status === 410 || res.status === 404;
    console.error(
      `Web Push send failed (status ${res.status}):`,
      await res.text().catch(() => '')
    );
    return { endpoint, ok: false, gone };
  } catch (e) {
    console.error('Web Push send threw:', e);
    return { endpoint, ok: false, gone: false };
  }
}

/** Clears any subscription the push service flagged as permanently gone. */
export async function pruneDeadSubscriptions(
  supabase: SupabaseClient,
  results: PushResult[]
): Promise<void> {
  const dead = [
    ...new Set(results.filter((r) => r.gone).map((r) => r.endpoint)),
  ];
  if (dead.length === 0) return;

  const { error } = await supabase
    .from('Users')
    .update({ push_endpoint: null, push_p256dh: null, push_auth: null })
    .in('push_endpoint', dead);

  if (error) {
    console.error('Failed to prune dead push subscriptions:', error.message);
  } else {
    console.log(`Pruned ${dead.length} dead push subscription(s)`);
  }
}
