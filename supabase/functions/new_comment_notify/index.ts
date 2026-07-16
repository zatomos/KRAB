import { createClient } from 'npm:@supabase/supabase-js@2';
import { isReachable, PUSH_COLUMNS, sendPush } from '../_shared/fcm.ts';
import type { PushSubscriptionRow } from '../_shared/fcm.ts';

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

    // Fetch the uploader's push target
    const { data: uploaderData, error: uploaderError } = await supabase
      .from('Users')
      .select(`${PUSH_COLUMNS}, username`)
      .eq('id', uploaderId)
      .returns<PushSubscriptionRow & { username: string }>()
      .single();

    const uploaderSub =
      !uploaderError && isReachable(uploaderData) ? uploaderData : null;

    if (!uploaderSub) {
      console.log('Uploader is not reachable for push, or fetching them failed.');
    }

    // If this comment is a reply, resolve the parent comment's author.
    let parentAuthorId: string | null = null;
    let parentAuthorSub: PushSubscriptionRow | null = null;
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
          .select(PUSH_COLUMNS)
          .eq('id', parentAuthorId)
          .returns<PushSubscriptionRow>()
          .single();
        if (!parentUserError && isReachable(parentUser)) {
          parentAuthorSub = parentUser;
        } else {
          console.log('Parent comment author is not reachable for push.');
        }
      }
    }

    // Whoever we notify via the reply push is excluded from the uploader and
    // group pushes so one comment never double-notifies them.
    const replyDedupId = parentAuthorSub ? parentAuthorId : null;

    // Notify the parent comment's author that they were replied to.
    if (parentAuthorSub) {
      console.log('Sending reply notification to parent comment author');
      await sendPush(supabase, [parentAuthorSub], {
        type: 'comment_reply',
        comment_id: comment.id,
      });
    }

    // Notify the uploader, unless they were already notified as the replied-to
    // author above.
    if (
      uploaderSub &&
      uploaderId !== comment.user_id &&
      uploaderId !== replyDedupId
    ) {
      console.log('Sending notification to uploader');
      await sendPush(supabase, [uploaderSub], {
        type: 'new_comment',
        comment_id: comment.id,
      });
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
          .select(`id, ${PUSH_COLUMNS}, notify_group_comments`)
          .in('id', userIds)
          .returns<(PushSubscriptionRow & { id: string; notify_group_comments: boolean })[]>();

        if (usersError || !users) {
          console.error('Error fetching users:', usersError?.message);
        } else {
          const groupSubs = users.filter(
            (u) => u.notify_group_comments === true && isReachable(u)
          );

          await sendPush(supabase, groupSubs, {
            type: 'group_comment',
            comment_id: comment.id,
          });
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