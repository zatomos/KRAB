package fr.zatomos.krab

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.util.Log
import java.io.File
import kotlin.math.min

private const val TAG = "WidgetBitmapUtils"

// Cached on first call: this is a device constant that never changes within a process.
@Volatile private var cachedBitmapLimit = -1

fun systemBitmapLimit(context: Context): Int {
    if (cachedBitmapLimit != -1) return cachedBitmapLimit
    return try {
        val rid = context.resources.getIdentifier(
            "config_maxRemoteViewsMemoryUsage", "integer", "android"
        )
        (if (rid != 0) context.resources.getInteger(rid) else 20_971_520)
            .also { cachedBitmapLimit = it }
    } catch (e: Exception) {
        20_971_520.also { cachedBitmapLimit = it }
    }
}

fun Bitmap.toCircular(): Bitmap {
    val size = min(width, height)
    val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(output)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
    paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
    canvas.drawBitmap(this, Rect(0, 0, width, height), Rect(0, 0, size, size), paint)
    return output
}

/** Decode path scaled to fit within maxBytes of decoded memory.
 *  Returns null if path is null/blank, the file is missing, or decoding fails. */
fun loadScaledBitmap(path: String?, maxBytes: Int): Bitmap? {
    if (path.isNullOrEmpty()) return null
    val file = File(path.trim())
    if (!file.exists()) {
        Log.w(TAG, "loadScaledBitmap: file not found: ${file.absolutePath}")
        return null
    }
    return try {
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, opts)
        val rawBytes = opts.outWidth.toLong() * opts.outHeight * 4
        var sampleSize = 1
        while (rawBytes / (sampleSize.toLong() * sampleSize) > maxBytes) sampleSize *= 2
        opts.inJustDecodeBounds = false
        opts.inSampleSize = sampleSize
        BitmapFactory.decodeFile(file.absolutePath, opts)
    } catch (e: Exception) {
        Log.e(TAG, "loadScaledBitmap: decode failed: $path", e)
        null
    }
}
