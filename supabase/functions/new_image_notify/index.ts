import { createClient } from 'npm:@supabase/supabase-js@2'
import {
    getFcmAccessToken,
    pruneDeadTokens,
    sendToTokens,
} from '../_shared/fcm.ts'

interface ImageGroups {
    id: string;
    image_id: string;
    group_id: string;
}

interface WebhookPayload {
    type: 'INSERT'
    table: string
    record: ImageGroups
    schema: 'public'
    old_record: null | ImageGroups
}

const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

const supabase = createClient(Deno.env.get('SUPABASE_URL')!, SERVICE_ROLE_KEY)

Deno.serve(async (req) => {
    // Only the database webhook may call this edge function
    const token = (req.headers.get('Authorization') ?? '')
        .replace(/^Bearer\s+/i, '')
        .trim()
    if (token !== SERVICE_ROLE_KEY) {
        return new Response(JSON.stringify({ error: 'forbidden' }), { status: 403 })
    }
    console.log('Successfully authorized token')

    try {
        const payload: WebhookPayload = await req.json()

        if (payload.table !== 'ImageGroups' || payload.type !== 'INSERT') {
            return new Response(null, { status: 200 })
        }

        const { image_id: imageId, group_id: groupId } = payload.record

        // Fetch image data and sender info
        const { data: imageData, error: imageError } = await supabase
            .from('Images')
            .select('uploaded_by, description')
            .eq('id', imageId)
            .single()

        if (imageError || !imageData) {
            console.error('Error fetching image data:', imageError?.message)
            return new Response(null, { status: 500 })
        }

        const senderId = imageData.uploaded_by

        const { data: senderData, error: senderError } = await supabase
            .from('Users')
            .select('username')
            .eq('id', senderId)
            .single()

        const senderUsername = (!senderError && senderData) ? senderData.username : 'Someone'
        console.log('Sender username:', senderUsername)

        // Fetch group members excluding the sender
        const { data: members, error: membersError } = await supabase
            .from('Members')
            .select('user_id')
            .eq('group_id', groupId)
            .neq('user_id', senderId)

        if (membersError) {
            console.error('Error fetching members:', membersError.message)
            return new Response(null, { status: 500 })
        }

        if (!members || members.length === 0) {
            console.log('No members to notify.')
            return new Response(null, { status: 200 })
        }

        const userIds = members.map((m) => m.user_id)

        const { data: users, error: usersError } = await supabase
            .from('Users')
            .select('id, fcm_token')
            .in('id', userIds)

        if (usersError || !users) {
            console.error('Error fetching user FCM tokens:', usersError?.message)
            return new Response(null, { status: 500 })
        }

        const usersWithToken = users.filter((u) => u.fcm_token)

        // Claim each user in the dedup ledger so we notify them at most once per
        // image, even when the image is shared to several groups at once
        const { data: claimed, error: claimError } = await supabase
            .from('NotifiedImageUsers')
            .upsert(
                usersWithToken.map((u) => ({ image_id: imageId, user_id: u.id })),
                { onConflict: 'image_id,user_id', ignoreDuplicates: true }
            )
            .select('user_id')

        if (claimError) {
            console.error('Error claiming notification ledger:', claimError.message)
            return new Response(null, { status: 500 })
        }

        const claimedIds = new Set((claimed ?? []).map((c) => c.user_id))
        const usersToNotify = usersWithToken.filter((u) => claimedIds.has(u.id))

        if (usersToNotify.length === 0) {
            console.log('All members already notified for this image.')
            return new Response(null, { status: 200 })
        }

        const { accessToken, projectId } = await getFcmAccessToken()
        console.log('Firebase access token retrieved')

        const results = await sendToTokens(
            projectId,
            accessToken,
            usersToNotify.map((u) => u.fcm_token),
            { type: 'new_image', image_id: imageId, group_id: groupId }
        )
        await pruneDeadTokens(supabase, results)

        console.log('Webhook processing completed')

        return new Response(JSON.stringify({ message: 'Notifications sent' }), {
            headers: { 'Content-Type': 'application/json' },
        })
    } catch (error) {
        console.error('Error in webhook:', error)
        return new Response(null, { status: 500 })
    }
})
