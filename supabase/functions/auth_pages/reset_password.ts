// The page a password-reset email links to.
export const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>KRAB - Reset password</title>
    <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
          font-family: 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Helvetica Neue', Arial, sans-serif;
          background: #0f0f0f;
          color: #f0f0f0;
          min-height: 100vh;
          display: flex;
          align-items: center;
          justify-content: center;
          padding: 1.5rem;
        }
        .card {
          background: #1a1a1a;
          border: 0.5px solid #2e2e2e;
          border-radius: 20px;
          padding: 2.5rem 2rem;
          width: 100%;
          max-width: 400px;
        }
        .logo {
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 10px;
          margin-bottom: 2rem;
        }
        .logo-icon {
          width: 64px;
          height: 64px;
          border-radius: 16px;
          object-fit: contain;
        }
        .logo-text {
          font-size: 22px;
          font-weight: 700;
          letter-spacing: 2px;
          color: #fff;
        }
        h1 { font-size: 20px; font-weight: 800; color: #fff; margin-bottom: 0.4rem; }
        .subtitle { font-size: 14px; color: #888; margin-bottom: 2rem; line-height: 1.5; }
        label { display: block; font-size: 13px; color: #aaa; margin-bottom: 6px; }
        .field { position: relative; margin-bottom: 1rem; }
        .field input {
          display: block;
          width: 100%;
          background: #252525;
          border: 0.5px solid #333;
          border-radius: 10px;
          padding: 0.75rem 3rem 0.75rem 1rem;
          color: #f0f0f0;
          font-size: 15px;
          outline: none;
          transition: border-color 0.15s;
        }
        .field input:focus { border-color: #dd6b3a; }
        .reveal {
          position: absolute;
          top: 0;
          right: 0;
          width: 3rem;
          height: 100%;
          margin: 0;
          padding: 0;
          background: none;
          border: none;
          border-radius: 0 10px 10px 0;
          color: #888;
          display: flex;
          align-items: center;
          justify-content: center;
          cursor: pointer;
        }
        .reveal:hover { color: #f0f0f0; opacity: 1; }
        .reveal:active { transform: none; }
        .reveal:disabled { opacity: 0.4; cursor: not-allowed; }
        .reveal svg { width: 20px; height: 20px; display: block; }
        .reveal .icon-hide { display: none; }
        .reveal.revealed .icon-show { display: none; }
        .reveal.revealed .icon-hide { display: block; }
        button {
          width: 100%;
          background: #dd6b3a;
          color: #fff;
          border: none;
          border-radius: 10px;
          padding: 0.85rem;
          font-size: 15px;
          font-weight: 600;
          cursor: pointer;
          transition: opacity 0.15s, transform 0.1s;
          margin-top: 0.5rem;
        }
        button:hover { opacity: 0.9; }
        button:active { transform: scale(0.98); }
        button:disabled { opacity: 0.5; cursor: not-allowed; }
        .msg {
          font-size: 13px;
          padding: 0.75rem 1rem;
          border-radius: 8px;
          margin-top: 1rem;
          display: none;
        }
        .msg.error { background: #3a1010; color: #f88; border: 0.5px solid #5a2020; display: block; }
        .strength-bar {
          height: 3px;
          border-radius: 2px;
          background: #2e2e2e;
          margin-top: -0.6rem;
          margin-bottom: 1rem;
          overflow: hidden;
        }
        .strength-fill { height: 100%; border-radius: 2px; width: 0%; transition: width 0.2s, background 0.2s; }
    </style>
</head>
<body>
<div class="card">
    <div class="logo">
        <div class="logo-text">KRAB</div>
        <img class="logo-icon" src="https://raw.githubusercontent.com/zatomos/KRAB/main/logo/krab_logo.png" alt="KRAB" />
    </div>

    <div id="invalid-section" style="display:none; text-align:center; padding:1rem 0;">
        <div style="font-size:40px; margin-bottom:1rem;">⚠️</div>
        <h1 style="margin-bottom:0.5rem;">Invalid link</h1>
        <p class="subtitle">This reset link is invalid or has expired. Please request a new one from the app.</p>
    </div>

    <div id="form-section">
        <h1>Reset your password</h1>
        <p class="subtitle" id="subtitle">Enter a new password for your account.</p>

        <label for="password">New password</label>
        <div class="field">
            <input type="password" id="password" placeholder="At least 8 characters" oninput="updateStrength()" disabled />
            <button type="button" class="reveal" id="reveal-password" onclick="toggleReveal('password', this)" aria-label="Show password" aria-pressed="false" aria-controls="password" disabled>
                <svg class="icon-show" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>
                <svg class="icon-hide" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/></svg>
            </button>
        </div>
        <div class="strength-bar"><div class="strength-fill" id="strength-fill"></div></div>

        <label for="confirm">Confirm password</label>
        <div class="field">
            <input type="password" id="confirm" placeholder="Repeat your password" disabled />
            <button type="button" class="reveal" id="reveal-confirm" onclick="toggleReveal('confirm', this)" aria-label="Show password" aria-pressed="false" aria-controls="confirm" disabled>
                <svg class="icon-show" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>
                <svg class="icon-hide" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/></svg>
            </button>
        </div>

        <button id="btn" onclick="updatePassword()" disabled>Update password</button>
        <div class="msg" id="msg"></div>
    </div>

    <div id="success-section" style="display:none; text-align:center; padding:1rem 0;">
        <div style="font-size:40px; margin-bottom:1rem;">✅</div>
        <p style="color:#6f9; font-size:15px; font-weight:500;">Password updated!</p>
        <p style="color:#888; font-size:13px; margin-top:0.5rem;">You can now sign in with your new password in the app.</p>
    </div>
</div>

<script>
    const SUPABASE_URL = '%%SUPABASE_URL%%';
    const SUPABASE_ANON_KEY = '%%SUPABASE_ANON_KEY%%';

    const { createClient } = supabase;
    const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

    function showInvalid() {
      document.getElementById('form-section').style.display = 'none';
      document.getElementById('invalid-section').style.display = 'block';
    }

    function showForm(email) {
      document.getElementById('invalid-section').style.display = 'none';
      document.getElementById('password').disabled = false;
      document.getElementById('confirm').disabled = false;
      document.getElementById('reveal-password').disabled = false;
      document.getElementById('reveal-confirm').disabled = false;
      document.getElementById('btn').disabled = false;
      if (email) {
        document.getElementById('subtitle').textContent = 'Enter a new password for ' + email + '.';
      }
    }

    const params = new URLSearchParams(window.location.search);
    const hash = new URLSearchParams(window.location.hash.slice(1));
    const code = params.get('code');
    const hasRecoveryTokens = hash.get('type') === 'recovery' || !!hash.get('access_token');

    if (code) {
      client.auth.exchangeCodeForSession(code)
        .then(({ data, error }) => {
          if (error || !data?.session) {
            showInvalid();
          } else {
            showForm(data.session.user?.email);
          }
        })
        .catch(() => showInvalid());
    } else if (hasRecoveryTokens) {
      let timer = setTimeout(showInvalid, 8000);
      client.auth.onAuthStateChange((event, session) => {
        if (event === 'PASSWORD_RECOVERY') {
          clearTimeout(timer);
          showForm(session?.user?.email);
        }
      });
    } else {
      showInvalid();
    }

    function toggleReveal(inputId, btn) {
      const input = document.getElementById(inputId);
      const reveal = input.type === 'password';
      const start = input.selectionStart;
      const end = input.selectionEnd;
      input.type = reveal ? 'text' : 'password';
      btn.classList.toggle('revealed', reveal);
      btn.setAttribute('aria-pressed', String(reveal));
      btn.setAttribute('aria-label', reveal ? 'Hide password' : 'Show password');
      input.focus();
      try { input.setSelectionRange(start, end); } catch (e) { /* unsupported */ }
    }

    function updateStrength() {
      const val = document.getElementById('password').value;
      const fill = document.getElementById('strength-fill');
      let score = 0;
      if (val.length >= 8) score++;
      if (/[A-Z]/.test(val)) score++;
      if (/[0-9]/.test(val)) score++;
      if (/[^A-Za-z0-9]/.test(val)) score++;
      fill.style.width = (score / 4 * 100) + '%';
      fill.style.background = score <= 1 ? '#e24b4a' : score === 2 ? '#ef9f27' : score === 3 ? '#97c459' : '#1d9e75';
    }

    async function updatePassword() {
      const password = document.getElementById('password').value;
      const confirm = document.getElementById('confirm').value;
      const btn = document.getElementById('btn');
      const msg = document.getElementById('msg');

      msg.className = 'msg';
      msg.textContent = '';

      if (password.length < 8) {
        msg.className = 'msg error';
        msg.textContent = 'Password must be at least 8 characters.';
        return;
      }
      if (password !== confirm) {
        msg.className = 'msg error';
        msg.textContent = 'Passwords do not match.';
        return;
      }

      btn.disabled = true;
      btn.textContent = 'Updating...';

      const { error } = await client.auth.updateUser({ password });

      if (error) {
        msg.className = 'msg error';
        msg.textContent = error.message || 'Something went wrong. Please request a new reset link.';
        btn.disabled = false;
        btn.textContent = 'Update password';
      } else {
        document.getElementById('form-section').style.display = 'none';
        document.getElementById('success-section').style.display = 'block';
      }
    }
</script>
</body>
</html>`;
