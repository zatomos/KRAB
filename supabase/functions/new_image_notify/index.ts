// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

import { createClient } from 'npm:@supabase/supabase-js@2'
import { JWT } from 'npm:google-auth-library@9'

interface ImageGroups {
    id: string;
    image_id: string,
    group_id: string
}

interface WebhookPayload {
    type: 'INSERT'
    table: string
    record: ImageGroups
    schema: 'public'
    old_record: null | ImageGroups
}

const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    Deno.serve(async (req) => {
        const payload: WebhookPayload = await req.json()

    // Fetch the group name
    const { data: groupData, error: groupError } = await supabase
        .from('Groups')
        .select('name')
        .eq('id', payload.record.group_id)
        .single();

    if (groupError || !groupData) {
        console.error('Error fetching group name:', groupError?.message);
        return new Response(null, { status: 500 });
    }

    const groupName = groupData.name;

    // Fetch the user who sent the image
    const { data: imageData, error: imageError } = await supabase
        .from('Images')
        .select('uploaded_by, description')
        .eq('id', payload.record.image_id)
        .single();

    if (imageError || !imageData) {
        console.error('Error fetching image data:', imageError?.message);
        return new Response(null, { status: 500 });
    }

    const senderUserId = imageData.uploaded_by;
    const imageDescription = imageData.description;

    // Fetch the sender's username
    const { data: senderData, error: senderError } = await supabase
        .from('Users')
        .select('username')
        .eq('id', senderUserId)
        .single();

    let senderUsername = 'Unknown';

    if (!senderError && senderData) {
        senderUsername = senderData.username;
    }

    // Fetch all user IDs who are part of the group
    const { data: members, error: membersError } = await supabase
      .from('Members')
      .select('user_id')
      .eq('group_id', payload.record.group_id);

    if (membersError) {
      console.error('Error fetching members:', membersError.message);
      return new Response(null, { status: 500 });
    }

    if (!members || members.length === 0) {
      console.log('No members found for the group.');
      return new Response(null, { status: 200 });
    }

    // Extract user IDs
    const userIds = members.map((member) => member.user_id);

    // Fetch FCM tokens from the Users table
    const { data: users, error: usersError } = await supabase
      .from('Users')
      .select('fcm_token')
      .in('id', userIds);  // Filter by user IDs

    if (usersError) {
      console.error('Error fetching user FCM tokens:', usersError.message);
      return new Response(null, { status: 500 });
    }

    // Extract valid FCM tokens
    const fcmTokens = users
      .map((user) => user.fcm_token as string)
      .filter((token) => !!token);  // Remove null/undefined tokens

    if (fcmTokens.length === 0) {
      console.log('No valid FCM tokens found.');
      return new Response(null, { status: 200 });
    }

    const serviceAccount = JSON.parse(
      Deno.env.get('GOOGLE_SERVICE_ACCOUNT')!
    );

    const accessToken = await getAccessToken({
      clientEmail: serviceAccount.client_email,
      privateKey: serviceAccount.private_key,
    });

    // Send a notification to each user token individually
    for (const token of fcmTokens) {
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
                        token: token, // Send to one token at a time
                        notification: {
                            title: `${senderUsername} sent an image in group ${groupName}`,
                            body: imageDescription,
                        },
                        data: {
                            type: 'new_image',
                            image_id: payload.record.image_id,
                            group_id: payload.record.group_id,
                            },
                    },
                }),
            }
        );

        const resData = await res.json();
        if (!res.ok) {
            console.error(`Error sending notification to token ${token}:`, resData);
        } else {
            console.log(`Notification sent successfully to token ${token}:`, resData);
        }
    }

    return new Response(JSON.stringify({ message: "Notifications sent" }), { headers: { "Content-Type": "application/json" } });
})

const getAccessToken = ({
    clientEmail,
    privateKey
}: { clientEmail: string; privateKey: string }): Promise<string> => {
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
