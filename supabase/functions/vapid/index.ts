// Serves this instance's VAPID public key.
//
// The app must present this key to a distributor to open a Web Push
// subscription, and it needs it before the user logs in, so unlike every
// other function here, this one is deliberately public.
//
// This function touches no database and takes no input, so it has no surface to
// attack. It reads exactly one environment variable, by name, and returns it.

const PUBLIC_KEY = Deno.env.get('VAPID_PUBLIC_KEY') ?? '';

const JSON_HEADERS = {
  'Content-Type': 'application/json',
  'Cache-Control': 'public, max-age=3600',
};

Deno.serve((req) => {
  if (req.method !== 'GET' && req.method !== 'POST') {
    return new Response(null, { status: 405 });
  }

  if (!PUBLIC_KEY) {
    console.error('VAPID_PUBLIC_KEY is not set; run setup_backend.sh');
    return new Response(
      JSON.stringify({ error: 'push is not configured on this instance' }),
      { status: 503, headers: JSON_HEADERS }
    );
  }

  return new Response(JSON.stringify({ vapid_public_key: PUBLIC_KEY }), {
    status: 200,
    headers: JSON_HEADERS,
  });
});
