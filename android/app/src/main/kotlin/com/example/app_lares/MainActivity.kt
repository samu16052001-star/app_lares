package com.example.app_lares

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/** A view of the process-owned acquisition engine, never its owner. */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        LaresAcquisitionRuntime.activityAttached = true
        super.onCreate(savedInstanceState)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        LaresAcquisitionRuntime.engine(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Plugins and native channels are registered once by the runtime. Registering
        // them here would replace live listeners every time an Activity is recreated.
    }

    override fun onResume() {
        super.onResume()
        LaresAcquisitionRuntime.onActivityResumed()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        LaresAcquisitionRuntime.onActivityResumed()
    }

    override fun onDestroy() {
        super.onDestroy()
        LaresAcquisitionRuntime.onActivityDestroyed(applicationContext, isChangingConfigurations)
        // Detaching the rendering surface must not destroy the isolate, GATT
        // clients, Polar SDK, location subscription, timers, or CSV writers.
    }
}
