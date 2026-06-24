import { createClient } from 'npm:@supabase/supabase-js@2'
import { JWT } from 'npm:google-auth-library@9'

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

        const serviceAccount = JSON.parse(Deno.env.get('GOOGLE_SERVICE_ACCOUNT')!)
        const accessToken = await getAccessToken({
            clientEmail: serviceAccount.client_email,
            privateKey: serviceAccount.private_key,
        })

        console.log('Firebase access token retrieved')

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
                                type: 'new_image',
                                image_id: imageId,
                                group_id: groupId,
                            },
                        },
                    }),
                }
            )

            const resData = await res.json()
            if (!res.ok) {
                console.error(`Error sending notification to ${user.id}:`, resData)
            } else {
                console.log(`FCM response for ${user.id}:`, JSON.stringify(resData))
            }
        }

        console.log('Webhook processing completed')

        return new Response(JSON.stringify({ message: 'Notifications sent' }), {
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
