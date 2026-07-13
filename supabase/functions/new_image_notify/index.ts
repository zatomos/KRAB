import { createClient } from 'npm:@supabase/supabase-js@2'
import { isReachable, PUSH_COLUMNS, sendPush } from '../_shared/webpush.ts'
import type { PushSubscriptionRow } from '../_shared/webpush.ts'

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
            .select(`id, ${PUSH_COLUMNS}`)
            .in('id', userIds)
            .returns<(PushSubscriptionRow & { id: string })[]>()

        if (usersError || !users) {
            console.error('Error fetching push targets:', usersError?.message)
            return new Response(null, { status: 500 })
        }

        // Only fully reachable users take part in the dedup below. A user with a
        // half-written subscription would otherwise win a group and then be
        // dropped at send time, silently losing the notification the other group
        // would have sent them.
        const usersWithSub = users.filter(isReachable)

        // Sending one photo to several groups fires this webhook once per group,
        // so somebody in two of them would be told twice about the same photo.
        //
        // Each one works out whether it speaks for a given person: among the groups this photo
        // reached in the same send, the lowest by id owns that person, and only that group's run
        // notifies them.
        //
        // Adding an old photo to another group later is its own event and fires this webhook again.
        const { data: imageGroups, error: imageGroupsError } = await supabase
            .from('ImageGroups')
            .select('group_id, uploaded_at')
            .eq('image_id', imageId)

        if (imageGroupsError || !imageGroups) {
            console.error('Error fetching the image groups:', imageGroupsError?.message)
            return new Response(null, { status: 500 })
        }

        const sentAt = imageGroups.find((g) => g.group_id === groupId)?.uploaded_at
        const batch = imageGroups
            .filter((g) => g.uploaded_at === sentAt)
            .map((g) => g.group_id)

        const { data: memberships, error: membershipsError } = await supabase
            .from('Members')
            .select('user_id, group_id')
            .in('group_id', batch)
            .in('user_id', usersWithSub.map((u) => u.id))

        if (membershipsError || !memberships) {
            console.error('Error fetching memberships:', membershipsError?.message)
            return new Response(null, { status: 500 })
        }

        const owningGroup = new Map<string, string>()
        for (const m of memberships) {
            const current = owningGroup.get(m.user_id)
            if (current === undefined || m.group_id < current) {
                owningGroup.set(m.user_id, m.group_id)
            }
        }

        const usersToNotify = usersWithSub.filter(
            (u) => owningGroup.get(u.id) === groupId
        )

        if (usersToNotify.length === 0) {
            console.log('Another group in this send speaks for these members.')
            return new Response(null, { status: 200 })
        }

        await sendPush(supabase, usersToNotify, {
            type: 'new_image',
            image_id: imageId,
            group_id: groupId,
            group_ids: batch.join(','),
        })

        console.log('Webhook processing completed')

        return new Response(JSON.stringify({ message: 'Notifications sent' }), {
            headers: { 'Content-Type': 'application/json' },
        })
    } catch (error) {
        console.error('Error in webhook:', error)
        return new Response(null, { status: 500 })
    }
})
