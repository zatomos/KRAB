import { HTML as confirmationEmail } from './confirmation_email.ts';
import { HTML as confirmed } from './confirmed.ts';
import { HTML as recoveryEmail } from './recovery_email.ts';
import { HTML as resetPassword } from './reset_password.ts';

interface Page {
  html: string;
  substitutions?: Record<string, string>;
  cacheControl?: string;
}

// The origin a browser uses to reach this instance.
function publicApiUrl(): string {
  return (
    Deno.env.get('SUPABASE_PUBLIC_URL') ??
    Deno.env.get('API_EXTERNAL_URL') ??
    ''
  ).replace(/\/$/, '');
}

const PAGES: Record<string, Page> = {
  'reset-password': {
    html: resetPassword,
    substitutions: {
      SUPABASE_URL: publicApiUrl(),
      SUPABASE_ANON_KEY: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    },
    cacheControl: 'no-store',
  },
  'confirmed': { html: confirmed },
  'recovery-email': { html: recoveryEmail },
  'confirmation-email': { html: confirmationEmail },
};

// Substitute once at boot
const RENDERED = new Map<string, string>(
  Object.entries(PAGES).map(([name, page]) => {
    let body = page.html;
    for (const [key, value] of Object.entries(page.substitutions ?? {})) {
      if (!value) {
        console.error(
          `${key} is empty; /${name} will not work. Check the functions env in docker-compose.override.yml.`,
        );
      }
      body = body.replaceAll(`%%${key}%%`, () => value);
    }
    return [name, body];
  }),
);

Deno.serve((req) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return new Response(null, { status: 405 });
  }

  const name = new URL(req.url).pathname.split('/').filter(Boolean)[1] ?? '';
  const body = RENDERED.get(name);
  if (body === undefined) {
    return new Response('Not found', { status: 404 });
  }

  return new Response(req.method === 'HEAD' ? null : body, {
    status: 200,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': PAGES[name].cacheControl ?? 'public, max-age=300',
      'X-Content-Type-Options': 'nosniff',
    },
  });
});
