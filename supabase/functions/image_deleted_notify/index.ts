import { createClient } from 'npm:@supabase/supabase-js@2'
import { JWT } from 'npm:google-auth-library@9'

interface ImageGroups {
    id: string;
    image_id: string;
    group_id: string;
}

interface WebhookPayload {
    type: 'DELETE'
    table: string
    record: null
    schema: 'public'
    old_record: ImageGroups
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
            payload.table !== 'ImageGroups' ||
            payload.type !== 'DELETE' ||
            !payload.old_record
        ) {
            return new Response(null, { status: 200 })
        }

        const { image_id: imageId, group_id: groupId } = payload.old_record

        // Free the storage blobs, but only once the image no longer belongs to
        // any group. A per-group removal must keep the file for the remaining groups.
        const { data: stillExists } = await supabase
            .from('Images')
            .select('id')
            .eq('id', imageId)
            .maybeSingle()

        if (!stillExists) {
            try {
                await supabase.storage.from('images').remove([imageId])
                await supabase.storage.from('image-thumbnails').remove([imageId])
            } catch (e) {
                console.error('Error removing storage objects:', e)
            }
        }

        // Every member of the group is told the image is gone so their widget and
        // any standing notification can be cleared
        const { data: members, error: membersError } = await supabase
            .from('Members')
            .select('user_id')
            .eq('group_id', groupId)

        if (membersError) {
            console.error('Error fetching members:', membersError.message)
            return new Response(null, { status: 500 })
        }

        if (!members || members.length === 0) {
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

        const serviceAccount = JSON.parse(Deno.env.get('GOOGLE_SERVICE_ACCOUNT')!)
        const accessToken = await getAccessToken({
            clientEmail: serviceAccount.client_email,
            privateKey: serviceAccount.private_key,
        })

        for (const user of users) {
            if (!user.fcm_token) continue

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
                            token: user.fcm_token,
                            android: { priority: 'HIGH' },
                            data: {
                                type: 'image_deleted',
                                image_id: imageId,
                                group_id: groupId,
                            },
                        },
                    }),
                }
            )

            const resData = await res.json()
            if (!res.ok) {
                console.error(`Error sending deletion to ${user.id}:`, resData)
            }
        }

        return new Response(JSON.stringify({ message: 'Deletion notifications sent' }), {
            headers: { 'Content-Type': 'application/json' },
        })
    } catch (error) {
        console.error('Error in webhook:', error)
        return new Response(null, { status: 500 })
    }
})

const getAccessToken = ({
    clientEmail,
    privateKey,
}: { clientEmail: string; privateKey: string }): Promise<string> => {
    return new Promise((resolve, reject) => {
        const jwtClient = new JWT({
            email: clientEmail,
            key: privateKey,
            scopes: ['https://www.googleapis.com/auth/firebase.messaging'],
        })

        jwtClient.authorize((err, tokens) => {
            if (err) {
                reject(err)
            } else {
                resolve(tokens!.access_token)
            }
        })
    })
}
