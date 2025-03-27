// Follow the setup guide for Deno: https://deno.land/manual/getting_started/setup_your_environment

import { createClient } from 'npm:@supabase/supabase-js@2';
import { JWT } from 'npm:google-auth-library@9';

interface Comments {
    id: string;
  user_id: string;
  image_id: string;
  group_id: string;
  text: string;
  created_at: string;
}

interface WebhookPayload {
  type: 'INSERT';
  table: string;
  record: Comments;
  schema: 'public';
  old_record: null;
}

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
);

Deno.serve(async (req) => {
  try {
    const payload: WebhookPayload = await req.json();

    // Ensure we're handling an insert into the Comments table
    if (payload.table !== 'Comments' || payload.type !== 'INSERT') {
      return new Response(null, { status: 200 });
    }

    // Extract comment details
    const comment = payload.record;

    // Fetch the image details to get the uploader's ID and description
    const { data: imageData, error: imageError } = await supabase
      .from('Images')
      .select('uploaded_by, description')
      .eq('id', comment.image_id)
      .single();

    if (imageError || !imageData) {
      console.error('Error fetching image data:', imageError?.message);
      return new Response(null, { status: 500 });
    }

    const uploaderId = imageData.uploaded_by;

    // Fetch the commenter's username
    const { data: commenterData, error: commenterError } = await supabase
      .from('Users')
      .select('username')
      .eq('id', comment.user_id)
      .single();

    let commenterUsername = 'Someone';
    if (!commenterError && commenterData) {
      commenterUsername = commenterData.username;
    }

    // Fetch the uploader's FCM token
    const { data: uploaderData, error: uploaderError } = await supabase
      .from('Users')
      .select('fcm_token')
      .eq('id', uploaderId)
      .single();

    if (uploaderError || !uploaderData || !uploaderData.fcm_token) {
      console.log('Uploader has no FCM token or error fetching uploader info.');
      return new Response(null, { status: 200 });
    }

    const fcmToken = uploaderData.fcm_token;

    // Optionally, you could also include group name in the notification
    const { data: groupData, error: groupError } = await supabase
      .from('Groups')
      .select('name')
      .eq('id', comment.group_id)
      .single();

    let groupName = 'your group';
    if (!groupError && groupData) {
      groupName = groupData.name;
    }

    // Get FCM access token using a service account
    const { default: serviceAccount } = await import('../service-account.json', { with: { type: 'json' } });
    const accessToken = await getAccessToken({
      clientEmail: serviceAccount.client_email,
      privateKey: serviceAccount.private_key,
    });

    // Prepare the notification payload
    const notificationTitle = `${commenterUsername} commented on your image in ${groupName}`;
    const notificationBody = comment.text;
    const imageId = comment.image_id;
    const groupId = comment.group_id;

    // Send a push notification
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
            token: fcmToken,
            notification: {
              title: notificationTitle,
              body: notificationBody,
            },
            data: {
                type: 'new_comment',
                image_id: imageId,
                group_id: groupId,
              },
          },
        }),
      }
    );

    const resData = await res.json();
    if (!res.ok) {
      console.error(`Error sending notification:`, resData);
      return new Response(null, { status: 500 });
    } else {
      console.log(`Notification sent successfully:`, resData);
    }

    return new Response(JSON.stringify({ message: "Notification sent" }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("Error in webhook:", error);
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
