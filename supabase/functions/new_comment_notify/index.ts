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
    console.log('Comment:', comment);

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

    console.log('Commenter username:', commenterUsername);

    // Fetch the uploader's FCM token
    const { data: uploaderData, error: uploaderError } = await supabase
      .from('Users')
      .select('fcm_token, username')
      .eq('id', uploaderId)
      .single();

    const hasUploaderToken =
      !uploaderError && uploaderData && uploaderData.fcm_token;

    if (!hasUploaderToken) {
      console.log('Uploader has no FCM token or error fetching uploader info.');
    }

    const fcmToken = hasUploaderToken ? uploaderData.fcm_token : null;

    // Load service account
    const serviceAccount = JSON.parse(
      Deno.env.get('GOOGLE_SERVICE_ACCOUNT')!
    );

    const accessToken = await getAccessToken({
      clientEmail: serviceAccount.client_email,
      privateKey: serviceAccount.private_key,
    });

    console.log('Firebase access token retrieved');

    const imageId = comment.image_id;
    const groupId = comment.group_id;

    // Send a push notification to uploader
    if (hasUploaderToken && uploaderId !== comment.user_id) {
      console.log('Sending notification to uploader');

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
              android: { priority: 'HIGH' },
              data: {
                type: 'new_comment',
                image_id: imageId,
                group_id: groupId,
                commenter_id: comment.user_id,
                commenter_username: commenterUsername,
                comment_text: comment.text,
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
    }

    // Notify group members
    const { data: members, error: membersError } = await supabase
      .from('Members')
      .select('user_id')
      .eq('group_id', comment.group_id);

    if (membersError || !members) {
      console.error('Error fetching group members:', membersError?.message);
    } else {
      const userIds = members
        .map((m) => m.user_id)
        .filter((id) => id !== comment.user_id && id !== uploaderId);

      if (userIds.length > 0) {
        const { data: users, error: usersError } = await supabase
          .from('Users')
          .select('id, fcm_token, notify_group_comments')
          .in('id', userIds);

        if (usersError || !users) {
          console.error('Error fetching users:', usersError?.message);
        } else {
          const groupTokens = users
            .filter(
              (u) =>
                u.notify_group_comments === true &&
                u.fcm_token
            )
            .map((u) => u.fcm_token);

          for (const token of groupTokens) {
            await fetch(
              `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`,
              {
                method: 'POST',
                headers: {
                  'Content-Type': 'application/json',
                  Authorization: `Bearer ${accessToken}`,
                },
                body: JSON.stringify({
                  message: {
                    token,
                    android: { priority: 'HIGH' },
                    data: {
                      type: 'group_comment',
                      image_id: imageId,
                      group_id: groupId,
                      commenter_id: comment.user_id,
                      commenter_username: commenterUsername,
                      comment_text: comment.text,
                      uploader_username: uploaderData?.username ?? '',
                    },
                  },
                }),
              }
            );
          }
        }
      }
    }

    console.log('Webhook processing completed');

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