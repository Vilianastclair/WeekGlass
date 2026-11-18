# The original adapters deserialize unannotated school-specific data classes
# and nested DTOs with Gson. Their member names are part of each input format.
-keepattributes Signature,InnerClasses,EnclosingMethod
-keep class bean.** { *; }
-keep class parser.** { *; }
-keep class main.java.** { *; }
