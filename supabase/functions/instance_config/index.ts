// Serves the public, per-instance settings a client needs before it can do
// anything.
//
// Everything instance-specific has to be asked for at runtime. That is why this function,
// unlike every other one here, is deliberately public.


const CONFIG = {
  // The key the app must present to a distributor to open a Web Push
  // subscription. Each instance generates its own keypair; only the public half
  // is ever served.
  vapid_public_key: Deno.env.get('VAPID_PUBLIC_KEY') ?? '',

  // Where GoTrue should send the user after they follow a password-reset or a
  // confirmation link. Empty when the operator has not set that flow up.
  password_reset_url: Deno.env.get('PASSWORD_RESET_URL') ?? '',
  email_confirm_url: Deno.env.get('EMAIL_CONFIRM_URL') ?? '',
};

const JSON_HEADERS = {
  'Content-Type': 'application/json',
  'Cache-Control': 'public, max-age=3600',
};

Deno.serve((req) => {
  if (req.method !== 'GET' && req.method !== 'POST') {
    return new Response(null, { status: 405 });
  }

  if (!CONFIG.vapid_public_key) {
    console.error('VAPID_PUBLIC_KEY is not set; run setup_backend.sh');
  }

  return new Response(JSON.stringify(CONFIG), {
    status: 200,
    headers: JSON_HEADERS,
  });
});
