import { createClient } from 'npm:@supabase/supabase-js@2';
import { JWT } from 'npm:google-auth-library@9';

interface Reaction {
  image_id: string;
  user_id: string;
  emoji: string;
}

interface WebhookPayload {
  type: 'INSERT';
  table: string;
  record: Reaction;
  schema: 'public';
  old_record: null;
}

const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const supabase = createClient(Deno.env.get('SUPABASE_URL')!, SERVICE_ROLE_KEY);

Deno.serve(async (req) => {
  // Only the database webhook may call this edge function
  const token = (req.headers.get('Authorization') ?? '')
    .replace(/^Bearer\s+/i, '')
    .trim();
  if (token !== SERVICE_ROLE_KEY) {
    return new Response(JSON.stringify({ error: 'forbidden' }), { status: 403 });
  }
  console.log('Successfully authorized token');

  try {
    const payload: WebhookPayload = await req.json();

    // Ensure we're handling an insert into the Reactions table
    if (payload.table !== 'Reactions' || payload.type !== 'INSERT') {
      return new Response(null, { status: 200 });
    }

    const reaction = payload.record;
    console.log('Reaction:', reaction);

    // Fetch the image's uploader
    const { data: imageData, error: imageError } = await supabase
      .from('Images')
      .select('uploaded_by')
      .eq('id', reaction.image_id)
      .single();

    if (imageError || !imageData) {
      console.error('Error fetching image data:', imageError?.message);
      return new Response(null, { status: 500 });
    }

    const uploaderId = imageData.uploaded_by;

    // Never notify someone for reacting to their own image.
    if (uploaderId === reaction.user_id) {
      return new Response(JSON.stringify({ message: 'Self reaction, skipped' }), {
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const { data: uploaderData, error: uploaderError } = await supabase
      .from('Users')
      .select('fcm_token')
      .eq('id', uploaderId)
      .single();

    if (uploaderError || !uploaderData) {
      console.error('Error fetching uploader info:', uploaderError?.message);
      return new Response(null, { status: 500 });
    }

    if (!uploaderData.fcm_token) {
      console.log('Uploader has no FCM token.');
      return new Response(JSON.stringify({ message: 'No notification sent' }), {
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Load service account
    const serviceAccount = JSON.parse(Deno.env.get('GOOGLE_SERVICE_ACCOUNT')!);

    const accessToken = await getAccessToken({
      clientEmail: serviceAccount.client_email,
      privateKey: serviceAccount.private_key,
    });

    console.log('Firebase access token retrieved, notifying uploader');

    const res = await fetch(
      `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${accessToken}`,
        },
        body: JSON.stringify({
          message: {
            token: uploaderData.fcm_token,
            android: { priority: 'HIGH' },
            data: {
              type: 'new_reaction',
              image_id: reaction.image_id,
              reactor_id: reaction.user_id,
              emoji: reaction.emoji,
            },
          },
        }),
      }
    );

    const resData = await res.json();
    if (!res.ok) {
      console.error('Error sending uploader notification:', resData);
      return new Response(null, { status: 500 });
    }
    console.log('FCM uploader response:', JSON.stringify(resData));

    return new Response(JSON.stringify({ message: 'Notification sent' }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (error) {
    console.error('Error in webhook:', error);
    return new Response(null, { status: 500 });
  }
});

const getAccessToken = ({
  clientEmail,
  privateKey,
}: {
  clientEmail: string;
  privateKey: string;
}): Promise<string> => {
  return new Promise((resolve, reject) => {
    const jwtClient = new JWT({
      email: clientEmail,
      key: privateKey,
      scopes: ['https://www.googleapis.com/auth/firebase.messaging'],
    });

    jwtClient.authorize((err, tokens) => {
      if (err) {
        reject(err);
      } else {
        resolve(tokens!.access_token);
      }
    });
  });
};
