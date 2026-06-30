package fr.zatomos.krab

import android.appwidget.AppWidgetManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.widget.RemoteViews
import androidx.exifinterface.media.ExifInterface
import java.io.File
import kotlin.math.min
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val TAG = "WidgetBitmapUtils"

@Volatile private var cachedBitmapLimit = -1

/** Returns the current bitmap limit. Starts at 20 MB; refined downward after any overflow. */
fun systemBitmapLimit(): Int {
    if (cachedBitmapLimit != -1) return cachedBitmapLimit
    return (20 * 1024 * 1024).also {
        cachedBitmapLimit = it
        Log.i(TAG, "Widget bitmap limit: using ${it / 1024}KB initial estimate")
    }
}

/**
 * Refines the bitmap limit after a bitmap-overflow failure, using the first
 * available source in order:
 *   1. Actual limit parsed from the exception message
 *   2. Conservative screen-size estimate via DisplayManager.getRealMetrics
 *   3. Hardcoded 3 MB floor
 */
fun refineCachedLimitFromError(context: Context, message: String) {
    val prev = cachedBitmapLimit

    // 1. Parse from error
    val fromError = Regex("""max:\s*(\d+)""").find(message)
        ?.groupValues?.get(1)?.toIntOrNull()
    if (fromError != null && fromError > 0) {
        Log.i(TAG, "Bitmap limit from error: ${fromError / 1024}KB (was ${prev / 1024}KB)")
        cachedBitmapLimit = fromError
        return
    }

    // 2. Screen-size estimate
    val fromScreen = try {
        val dm = DisplayMetrics()
        (context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager)
            .getDisplay(Display.DEFAULT_DISPLAY)
            .getRealMetrics(dm)
        val pixels = minOf(dm.widthPixels, dm.heightPixels).toLong() *
            maxOf(dm.widthPixels, dm.heightPixels)
        (pixels * 4 * 0.70).toLong().coerceAtMost(20_971_520L).toInt()
    } catch (_: Exception) { 0 }
    if (fromScreen > 0) {
        Log.i(TAG, "Bitmap limit from screen: ${fromScreen / 1024}KB (was ${prev / 1024}KB)")
        cachedBitmapLimit = fromScreen
        return
    }

    // 3. Hardcoded fallback
    Log.i(TAG, "Bitmap limit: using 3MB hardcoded fallback (was ${prev / 1024}KB)")
    cachedBitmapLimit = 3 * 1024 * 1024
}

/**
 * Calls AppWidgetManager.updateAppWidget on the main thread. Returns true on success.
 * On a bitmap-memory overflow, refines the bitmap limit and returns false so the caller
 * can rebuild views with a smaller budget and retry.
 */
suspend fun AppWidgetManager.tryUpdateAppWidget(
    context: Context,
    widgetId: Int,
    views: RemoteViews
): Boolean {
    return try {
        withContext(Dispatchers.Main) { updateAppWidget(widgetId, views) }
        true
    } catch (e: IllegalArgumentException) {
        val msg = e.message.orEmpty()
        if (msg.contains("bitmap", ignoreCase = true)) {
            refineCachedLimitFromError(context, msg)
            Log.w(TAG, "Widget $widgetId: bitmap limit exceeded, refined to ${cachedBitmapLimit / 1024}KB")
            false
        } else throw e
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

/** Decode path scaled to fit within maxBytes of decoded memory. */
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
        val bitmap = BitmapFactory.decodeFile(file.absolutePath, opts) ?: return null
        bitmap.applyExifOrientation(file)
    } catch (e: Exception) {
        Log.e(TAG, "loadScaledBitmap: decode failed: $path", e)
        null
    }
}

/**
 * Rotates/flips the bitmap to match the EXIF orientation tag of a file.
 */
private fun Bitmap.applyExifOrientation(file: File): Bitmap {
    val orientation = try {
        ExifInterface(file.absolutePath)
            .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
    } catch (e: Exception) {
        Log.w(TAG, "applyExifOrientation: read failed: ${file.absolutePath}", e)
        return this
    }

    val matrix = Matrix()
    when (orientation) {
        ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
        ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
        ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
        ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
        ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.postRotate(90f); matrix.postScale(-1f, 1f) }
        ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.postRotate(270f); matrix.postScale(-1f, 1f) }
        else -> return this
    }

    return try {
        val rotated = Bitmap.createBitmap(this, 0, 0, width, height, matrix, true)
        if (rotated != this) recycle()
        rotated
    } catch (e: OutOfMemoryError) {
        Log.w(TAG, "applyExifOrientation: rotate OOM, using original", e)
        this
    }
}
