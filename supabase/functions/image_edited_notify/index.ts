import { createClient } from 'npm:@supabase/supabase-js@2'
import { PUSH_COLUMNS, sendPush } from '../_shared/fcm.ts'
import type { PushSubscriptionRow } from '../_shared/fcm.ts'

interface Image {
    id: string;
    uploaded_by: string;
    description: string | null;
    share_id: string | null;
}

interface WebhookPayload {
    type: 'UPDATE'
    table: string
    record: Image
    schema: 'public'
    old_record: Image | null
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

    try {
        const payload: WebhookPayload = await req.json()

        if (
            payload.table !== 'Images' ||
            payload.type !== 'UPDATE' ||
            !payload.record
        ) {
            return new Response(null, { status: 200 })
        }

        if (payload.old_record &&
            payload.old_record.description === payload.record.description) {
            return new Response(null, { status: 200 })
        }

        const imageId = payload.record.id
        const senderId = payload.record.uploaded_by

        const { data: imageGroups, error: imageGroupsError } = await supabase
            .from('ImageGroups')
            .select('group_id')
            .eq('image_id', imageId)

        if (imageGroupsError || !imageGroups) {
            console.error('Error fetching the image groups:', imageGroupsError?.message)
            return new Response(null, { status: 500 })
        }

        if (imageGroups.length === 0) {
            return new Response(null, { status: 200 })
        }

        // Exclude the uploader
        const { data: members, error: membersError } = await supabase
            .from('Members')
            .select('user_id')
            .in('group_id', imageGroups.map((g) => g.group_id))
            .neq('user_id', senderId)

        if (membersError) {
            console.error('Error fetching members:', membersError.message)
            return new Response(null, { status: 500 })
        }

        if (!members || members.length === 0) {
            return new Response(null, { status: 200 })
        }

        const userIds = [...new Set(members.map((m) => m.user_id))]

        const { data: users, error: usersError } = await supabase
            .from('Users')
            .select(`id, ${PUSH_COLUMNS}`)
            .in('id', userIds)
            .returns<PushSubscriptionRow[]>()

        if (usersError || !users) {
            console.error('Error fetching push targets:', usersError?.message)
            return new Response(null, { status: 500 })
        }

        await sendPush(supabase, users, {
            type: 'image_description_changed',
            image_id: imageId,
            share_id: payload.record.share_id ?? '',
        })

        return new Response(JSON.stringify({ message: 'Rewording notifications sent' }), {
            headers: { 'Content-Type': 'application/json' },
        })
    } catch (error) {
        console.error('Error in webhook:', error)
        return new Response(null, { status: 500 })
    }
})
