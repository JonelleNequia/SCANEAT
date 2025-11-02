package com.example.scanet

import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "config/meta"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "getMeta") {
                    try {
                        val appInfo = packageManager.getApplicationInfo(
                            packageName,
                            PackageManager.GET_META_DATA
                        )
                        val meta = appInfo.metaData
                        val map = hashMapOf<String, Any?>()
                        map["GEMINI_API_KEY"] = meta?.getString("GEMINI_API_KEY")
                        map["GOOGLE_CSE_KEY"] = meta?.getString("GOOGLE_CSE_KEY")
                        map["GOOGLE_CSE_CX"]  = meta?.getString("GOOGLE_CSE_CX")
                        result.success(map)
                    } catch (e: Exception) {
                        result.error("META_ERROR", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
