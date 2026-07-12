import { createClient } from 'npm:@supabase/supabase-js@2';
import { isReachable, PUSH_COLUMNS, sendPush } from '../_shared/webpush.ts';
import type { PushSubscriptionRow } from '../_shared/webpush.ts';

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

    // Notify the uploader, unless they reacted to their own image.
    if (uploaderId !== reaction.user_id) {
      const { data: uploaderData, error: uploaderError } = await supabase
        .from('Users')
        .select(PUSH_COLUMNS)
        .eq('id', uploaderId)
        .returns<PushSubscriptionRow>()
        .single();

      if (uploaderError || !uploaderData) {
        console.error('Error fetching uploader info:', uploaderError?.message);
      } else if (isReachable(uploaderData)) {
        console.log('Sending notification to uploader');
        await sendPush(supabase, [uploaderData], {
          type: 'new_reaction',
          image_id: reaction.image_id,
          reactor_id: reaction.user_id,
          emoji: reaction.emoji,
        });
      } else {
        console.log('Uploader is not reachable for push.');
      }
    }

    // Notify opted-in members of the groups the reactor actually shares with
    // them
    const { data: imageGroups, error: groupsError } = await supabase
      .from('ImageGroups')
      .select('group_id')
      .eq('image_id', reaction.image_id);

    if (groupsError || !imageGroups) {
      console.error('Error fetching image groups:', groupsError?.message);
    } else {
      const imageGroupIds = imageGroups.map((g) => g.group_id);

      // Restrict to the image's groups the reactor is a member of.
      const { data: reactorGroups, error: reactorGroupsError } =
        imageGroupIds.length > 0
          ? await supabase
              .from('Members')
              .select('group_id')
              .eq('user_id', reaction.user_id)
              .neq('role', 'banned')
              .in('group_id', imageGroupIds)
          : { data: [], error: null };

      if (reactorGroupsError) {
        console.error(
          'Error fetching reactor memberships:',
          reactorGroupsError.message
        );
      }

      const groupIds = (reactorGroups ?? []).map((g) => g.group_id);

      if (groupIds.length > 0) {
        const { data: members, error: membersError } = await supabase
          .from('Members')
          .select('user_id')
          .in('group_id', groupIds);

        if (membersError || !members) {
          console.error('Error fetching group members:', membersError?.message);
        } else {
          // Dedupe members that share more than one of the image's groups, and
          // exclude the reactor and the uploader
          const userIds = [...new Set(members.map((m) => m.user_id))].filter(
            (id) => id !== reaction.user_id && id !== uploaderId
          );

          if (userIds.length > 0) {
            const { data: users, error: usersError } = await supabase
              .from('Users')
              .select(`id, ${PUSH_COLUMNS}, notify_group_reactions`)
              .in('id', userIds)
              .returns<(PushSubscriptionRow & { id: string; notify_group_reactions: boolean })[]>();

            if (usersError || !users) {
              console.error('Error fetching users:', usersError?.message);
            } else {
              const groupSubs = users.filter(
                (u) => u.notify_group_reactions === true && isReachable(u)
              );

              await sendPush(supabase, groupSubs, {
                type: 'group_reaction',
                image_id: reaction.image_id,
                reactor_id: reaction.user_id,
                emoji: reaction.emoji,
              });
            }
          }
        }
      }
    }

    return new Response(JSON.stringify({ message: 'Notification sent' }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (error) {
    console.error('Error in webhook:', error);
    return new Response(null, { status: 500 });
  }
});
