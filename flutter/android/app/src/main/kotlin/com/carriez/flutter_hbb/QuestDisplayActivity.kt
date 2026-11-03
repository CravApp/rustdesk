package com.carriez.flutter_hbb

/**
 * Quest multi-window (fork).
 *
 * One Horizon OS 2D panel per remote display. Each instance runs its own Flutter engine
 * (Dart entrypoint `questDisplayMain` in main.dart) in the same process, so it shares the
 * Rust core and the peer connection with the main window. The secondary engine joins the
 * existing connection as an extra "ui session" (`sessionAddExistedSync` +
 * `sessionStartWithDisplays`) that only renders / controls its display.
 *
 * Launched by [MainActivity] (`quest_open_display_window`) with
 * FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_MULTIPLE_TASK | FLAG_ACTIVITY_LAUNCH_ADJACENT,
 * so Horizon OS opens it as a new panel next to the main one.
 */

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.lang.ref.WeakReference

class QuestDisplayActivity : FlutterActivity() {
    companion object {
        private const val logTag = "QuestDisplayActivity"
        const val EXTRA_PEER_ID = "quest_peer_id"
        const val EXTRA_DISPLAY = "quest_display"
        const val EXTRA_SESSION_ID = "quest_session_id"
        const val EXTRA_CACHED_DATA = "quest_cached_data"
        const val EXTRA_TITLE = "quest_title"
        const val EXTRA_IS_QUEST = "quest_is_quest"

        // display index -> activity
        private val windows = HashMap<Int, WeakReference<QuestDisplayActivity>>()

        fun open(context: Context, args: Map<*, *>): Boolean {
            val display = (args["display"] as? Number)?.toInt() ?: return false
            val intent = Intent(context, QuestDisplayActivity::class.java).apply {
                putExtra(EXTRA_PEER_ID, args["peer_id"] as? String ?: "")
                putExtra(EXTRA_DISPLAY, display)
                putExtra(EXTRA_SESSION_ID, args["session_id"] as? String ?: "")
                putExtra(EXTRA_CACHED_DATA, args["cached_data"] as? String ?: "")
                putExtra(EXTRA_TITLE, args["title"] as? String ?: "RustDesk ${display + 1}")
                putExtra(EXTRA_IS_QUEST, args["is_quest"] as? Boolean ?: true)
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_MULTIPLE_TASK or
                        Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT
                )
            }
            return try {
                // Close a stale window of the same display first.
                close(display)
                context.startActivity(intent)
                true
            } catch (e: Exception) {
                Log.e(logTag, "Failed to open display window $display: ${e.message}", e)
                false
            }
        }

        fun close(display: Int) {
            windows.remove(display)?.get()?.let {
                it.closedByMain = true
                it.finishAndRemoveTask()
            }
        }

        fun closeAll() {
            val all = windows.values.mapNotNull { it.get() }
            windows.clear()
            for (a in all) {
                a.closedByMain = true
                a.finishAndRemoveTask()
            }
        }
    }

    private var display = -1
    private var sessionId = ""
    private var closedByMain = false
    private var notified = false

    override fun onCreate(savedInstanceState: Bundle?) {
        display = intent.getIntExtra(EXTRA_DISPLAY, -1)
        sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: ""
        if (display >= 0) {
            windows[display] = WeakReference(this)
        }
        super.onCreate(savedInstanceState)
        title = intent.getStringExtra(EXTRA_TITLE) ?: "RustDesk"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            setTaskDescription(android.app.ActivityManager.TaskDescription(title.toString()))
        }
    }

    // Dart entrypoint for the secondary engine (see `questDisplayMain` in lib/main.dart).
    override fun getDartEntrypointFunctionName(): String = "questDisplayMain"

    override fun getDartEntrypointArgs(): List<String> {
        val json = JSONObject()
        json.put("peer_id", intent.getStringExtra(EXTRA_PEER_ID) ?: "")
        json.put("display", intent.getIntExtra(EXTRA_DISPLAY, 0))
        json.put("session_id", intent.getStringExtra(EXTRA_SESSION_ID) ?: "")
        json.put("cached_data", intent.getStringExtra(EXTRA_CACHED_DATA) ?: "")
        json.put("title", intent.getStringExtra(EXTRA_TITLE) ?: "")
        json.put("is_quest", intent.getBooleanExtra(EXTRA_IS_QUEST, true))
        return listOf(json.toString())
    }

    // Each panel has its own engine, never a cached one.
    override fun getCachedEngineId(): String? = null

    override fun shouldDestroyEngineWithHost(): Boolean = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Minimal "mChannel" for the remote page of this panel. Do NOT touch
        // MainActivity.flutterMethodChannel: it belongs to the main engine (service events).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mChannel")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enable_soft_keyboard" -> {
                        if (call.arguments as? Boolean == true) {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
                        } else {
                            window.addFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
                        }
                        result.success(true)
                    }
                    "try_sync_clipboard" -> {
                        MainActivity.rdClipboardManager?.syncClipboard(true)
                        result.success(true)
                    }
                    "quest_window_finish" -> {
                        result.success(true)
                        runOnUiThread { finishAndRemoveTask() }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        notifyClosed()
        if (display >= 0 && windows[display]?.get() === this) {
            windows.remove(display)
        }
        super.onDestroy()
    }

    // Tell the main engine, so it releases this panel's ui session (stops capturing the
    // display if no other panel shows it). The Dart isolate of this panel is gone by now.
    private fun notifyClosed() {
        if (notified) return
        notified = true
        try {
            MainActivity.flutterMethodChannel?.invokeMethod(
                "on_quest_window_closed",
                mapOf(
                    "display" to display,
                    "session_id" to sessionId,
                    "by_main" to closedByMain
                )
            )
        } catch (e: Exception) {
            Log.e(logTag, "notifyClosed: ${e.message}")
        }
    }
}
