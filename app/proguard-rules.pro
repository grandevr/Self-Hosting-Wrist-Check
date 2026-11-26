# Keep rules for the release build (R8).
#
# Nothing extra is needed today:
# - The complication service and the activities are named in AndroidManifest.xml, which R8 keeps
#   automatically (androidx.wear.watchface complications ship their own consumer rules).
# - JSON is parsed with the platform's org.json classes, by key, with no reflection.
# - Compose, activity-compose and ZXing ship their own consumer rules.
#
# Keep line numbers so a crash stack trace from `adb logcat` can still be read with the mapping
# file (app/build/outputs/mapping/release/mapping.txt).
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
