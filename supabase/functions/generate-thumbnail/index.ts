// Produces one static thumbnail per image in the `image-thumbnails` bucket so
// the app's gallery grid serves a static object.

/* Call this to backfill
/curl -s -X POST \
               -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
               -H "Content-Type: application/json" \
               -d '{"backfill": true, "force": true "limit": 150, "offset": 0}' \
               "$SUPABASE_URL/functions/v1/generate-thumbnail"
*/

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SOURCE_BUCKET = "images";
const THUMB_BUCKET = "image-thumbnails";
const THUMB_WIDTH = 600;
const THUMB_QUALITY = 50;

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

async function generateThumbnail(imageId: string): Promise<void> {
  const renderUrl =
    `${SUPABASE_URL}/storage/v1/render/image/authenticated/${SOURCE_BUCKET}/` +
    `${imageId}?width=${THUMB_WIDTH}&quality=${THUMB_QUALITY}`;

  const res = await fetch(renderUrl, {
    headers: {
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      Accept: "image/webp",
    },
  });
  if (!res.ok) {
    throw new Error(
      `render ${imageId} failed: ${res.status} ${await res.text()}`,
    );
  }

  const contentType = res.headers.get("content-type") ?? "image/jpeg";
  const bytes = new Uint8Array(await res.arrayBuffer());

  const { error: uploadError } = await admin.storage
    .from(THUMB_BUCKET)
    .upload(imageId, bytes, { contentType, upsert: true });
  if (uploadError) throw uploadError;
}

async function thumbnailExists(imageId: string): Promise<boolean> {
  const { data } = await admin.storage
    .from(THUMB_BUCKET)
    .list("", { search: imageId, limit: 1 });
  return !!data && data.some((o) => o.name === imageId);
}

Deno.serve(async (req) => {
    // Only the database webhook may call this edge function
  const token = (req.headers.get("Authorization") ?? "")
    .replace(/^Bearer\s+/i, "")
    .trim();
  if (token !== SERVICE_ROLE_KEY) {
    return Response.json({ success: false, error: "forbidden" }, {
      status: 403,
    });
  }
else {
    console.log("Successfully authorized token")
    }

  try {
    const body = await req.json().catch(() => ({} as Record<string, unknown>));

    // --- Backfill mode -----------------------------------------------------
    if (body.backfill === true) {
      const limit = Math.min(Number(body.limit ?? 200), 1000);
      const offset = Number(body.offset ?? 0);
      // force: re-generate even if a thumbnail object already exists (upsert
      // overwrites). Useful to repair metadata/files that drifted out of sync.
      const force = body.force === true;
      const { data: objects, error } = await admin.storage
        .from(SOURCE_BUCKET)
        .list("", {
          limit,
          offset,
          sortBy: { column: "name", order: "asc" },
        });
      if (error) throw error;

      let generated = 0;
      let skipped = 0;
      const failed: string[] = [];
      for (const obj of objects ?? []) {
        if (!force && (await thumbnailExists(obj.name))) {
          skipped++;
          continue;
        }
        try {
          await generateThumbnail(obj.name);
          generated++;
        } catch (e) {
          console.error("backfill failed for", obj.name, e);
          failed.push(obj.name);
        }
      }
      const scanned = objects?.length ?? 0;
      return Response.json({
        success: true,
        scanned,
        generated,
        skipped, // already had a thumbnail
        failed: failed.length, // unprocessable (e.g. HEIC / oversized source)
        failedIds: failed,
        nextOffset: offset + scanned,
        done: scanned < limit,
      });
    }

    // --- Single image (webhook record or explicit id) ----------------------
    let imageId: string | undefined = body.imageId as string | undefined;
    if (body.record && typeof body.record === "object") {
      const record = body.record as { bucket_id?: string; name?: string };
      if (record.bucket_id && record.bucket_id !== SOURCE_BUCKET) {
        return Response.json({ success: true, skipped: record.bucket_id });
      }
      imageId = record.name;
    }

    if (!imageId) {
      return Response.json(
        { success: false, error: "missing imageId" },
        { status: 400 },
      );
    }

    await generateThumbnail(imageId);
    return Response.json({ success: true, imageId });
  } catch (e) {
    console.error(e);
    return Response.json({ success: false, error: String(e) }, { status: 500 });
  }
});
