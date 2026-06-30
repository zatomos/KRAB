import { createClient } from 'npm:@supabase/supabase-js@2';
import {
  getFcmAccessToken,
  pruneDeadTokens,
  sendToTokens,
} from '../_shared/fcm.ts';
import type { FcmResult } from '../_shared/fcm.ts';

interface Comments {
  id: string;
  user_id: string;
  image_id: string;
  group_id: string;
  text: string;
  parent_id: string | null;
  created_at: string;
}

interface WebhookPayload {
  type: 'INSERT';
  table: string;
  record: Comments;
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

    // If this comment is a reply, resolve the parent comment's author.
    let parentAuthorId: string | null = null;
    let parentAuthorToken: string | null = null;
    if (comment.parent_id) {
      const { data: parent, error: parentError } = await supabase
        .from('Comments')
        .select('user_id')
        .eq('id', comment.parent_id)
        .single();

      if (parentError || !parent) {
        console.error('Error fetching parent comment:', parentError?.message);
      } else if (parent.user_id && parent.user_id !== comment.user_id) {
        parentAuthorId = parent.user_id;
        const { data: parentUser, error: parentUserError } = await supabase
          .from('Users')
          .select('fcm_token')
          .eq('id', parentAuthorId)
          .single();
        if (!parentUserError && parentUser?.fcm_token) {
          parentAuthorToken = parentUser.fcm_token;
        } else {
          console.log('Parent comment author has no FCM token.');
        }
      }
    }

    // Whoever we notify via the reply push is excluded from the uploader and
    // group pushes so one comment never double-notifies them.
    const replyDedupId = parentAuthorToken ? parentAuthorId : null;

    const { accessToken, projectId } = await getFcmAccessToken();
    console.log('Firebase access token retrieved');

    const allResults: FcmResult[] = [];

    // Notify the parent comment's author that they were replied to.
    if (parentAuthorToken) {
      console.log('Sending reply notification to parent comment author');
      allResults.push(
        ...(await sendToTokens(projectId, accessToken, [parentAuthorToken], {
          type: 'comment_reply',
          comment_id: comment.id,
        }))
      );
    }

    // Notify the uploader, unless they were already notified as the replied-to
    // author above.
    if (
      hasUploaderToken &&
      uploaderId !== comment.user_id &&
      uploaderId !== replyDedupId
    ) {
      console.log('Sending notification to uploader');
      allResults.push(
        ...(await sendToTokens(projectId, accessToken, [fcmToken], {
          type: 'new_comment',
          comment_id: comment.id,
        }))
      );
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
        .filter(
          (id) =>
            id !== comment.user_id &&
            id !== uploaderId &&
            id !== replyDedupId
        );

      if (userIds.length > 0) {
        const { data: users, error: usersError } = await supabase
          .from('Users')
          .select('id, fcm_token, notify_group_comments')
          .in('id', userIds);

        if (usersError || !users) {
          console.error('Error fetching users:', usersError?.message);
        } else {
          const groupTokens = users
            .filter((u) => u.notify_group_comments === true && u.fcm_token)
            .map((u) => u.fcm_token);

          allResults.push(
            ...(await sendToTokens(projectId, accessToken, groupTokens, {
              type: 'group_comment',
              comment_id: comment.id,
            }))
          );
        }
      }
    }

    await pruneDeadTokens(supabase, allResults);

    console.log('Webhook processing completed');

    return new Response(JSON.stringify({ message: 'Notification sent' }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (error) {
    console.error('Error in webhook:', error);
    return new Response(null, { status: 500 });
  }
});