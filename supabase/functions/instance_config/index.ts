// Serves the public, per-instance settings a client needs before it can do
// anything.
//
// Everything instance-specific has to be asked for at runtime. That is why this function,
// unlike every other one here, is deliberately public.

interface FcmConfig {
  app_id: string;
  api_key: string;
  sender_id: string;
  project_id: string;
}

// Strips a matching pair of surrounding quotes
function unquote(s: string | undefined): string {
  const t = (s ?? '').trim();
  if (
    t.length >= 2 &&
    ((t[0] === "'" && t[t.length - 1] === "'") ||
      (t[0] === '"' && t[t.length - 1] === '"'))
  ) {
    return t.slice(1, -1).trim();
  }
  return t;
}

// The raw google-services.json.
function googleServicesRaw(): string {
  try {
    const fromFile = Deno.readTextFileSync(
      new URL('../_shared/google-services.json', import.meta.url),
    ).trim();
    if (fromFile) return fromFile;
  } catch {
    // No file mounted; fall through to the env var.
  }
  return unquote(Deno.env.get('GOOGLE_SERVICES_JSON'));
}

// The public Firebase config the client needs to initialise FCM.
function fcmFromGoogleServices(): FcmConfig {
  const empty: FcmConfig = {
    app_id: '',
    api_key: '',
    sender_id: '',
    project_id: '',
  };

  const raw = googleServicesRaw();
  if (!raw) return empty;

  try {
    // deno-lint-ignore no-explicit-any
    const gs: any = JSON.parse(raw);
    const clients = gs.client ?? [];
    const wanted = Deno.env.get('FCM_PACKAGE_NAME');
    const client =
      (wanted
        ? clients.find(
            (c: any) =>
              c?.client_info?.android_client_info?.package_name === wanted,
          )
        : undefined) ?? clients[0];

    return {
      app_id: client?.client_info?.mobilesdk_app_id ?? '',
      api_key: client?.api_key?.[0]?.current_key ?? '',
      sender_id: gs.project_info?.project_number ?? '',
      project_id: gs.project_info?.project_id ?? '',
    };
  } catch (e) {
    console.error('GOOGLE_SERVICES_JSON is not valid JSON:', e);
    return empty;
  }
}

const CONFIG = {
  fcm: fcmFromGoogleServices(),

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

  if (!CONFIG.fcm.app_id || !CONFIG.fcm.project_id) {
    console.error('GOOGLE_SERVICES_JSON is missing or incomplete; push will not work');
  }

  return new Response(JSON.stringify(CONFIG), {
    status: 200,
    headers: JSON_HEADERS,
  });
});
