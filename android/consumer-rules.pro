# Added to the release build of every app that uses this package.
# The ML Kit text plugin refers to the Chinese, Devanagari, Japanese and
# Korean recognizers; only the Latin one is bundled.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
