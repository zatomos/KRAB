# Flutter
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }

# Keep annotations
-keepattributes *Annotation*
-keepattributes Signature

# Don't warn about common libs
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn com.google.android.play.core.**