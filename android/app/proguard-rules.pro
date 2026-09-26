# WorkManager creates its Room database reflectively; R8 full mode (AGP 9)
# otherwise strips the generated constructor and the app crashes at startup.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
