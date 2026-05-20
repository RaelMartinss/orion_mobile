package br.com.orion.mobile

import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val CHANNEL = "br.com.orion.mobile/accessibility"
    private var methodChannel: MethodChannel? = null

    // Cold start disparado pelo wake word: o engine já existe mas o handler Dart
    // pode ainda não estar registrado, então marcamos para entregar com atraso.
    private var pendingWakeWord = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // getIntent() já é válido aqui; precisa ser lido antes do super, pois é
        // o super.onCreate quem dispara configureFlutterEngine().
        if (intent?.action == OrionWakeWordService.ACTION_WAKE_WORD) {
            pendingWakeWord = true
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {

                "setKeepScreenOn" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }

                // ── Bateria ───────────────────────────────────────────────────
                "getBattery" -> {
                    val bm = getSystemService(BATTERY_SERVICE) as BatteryManager
                    val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                    val charging = bm.isCharging
                    result.success(mapOf("level" to level, "charging" to charging))
                }

                // ── Volume ────────────────────────────────────────────────────
                "setVolume" -> {
                    val delta    = call.argument<Int>("delta")    // +1 / -1
                    val absolute = call.argument<Int>("absolute") // 0-15
                    val mute     = call.argument<Boolean>("mute") ?: false
                    val stream   = call.argument<String>("stream") ?: "media"

                    val audioStream = if (stream == "ring")
                        AudioManager.STREAM_RING else AudioManager.STREAM_MUSIC
                    val am = getSystemService(AUDIO_SERVICE) as AudioManager

                    when {
                        mute -> am.adjustStreamVolume(audioStream, AudioManager.ADJUST_MUTE, 0)
                        absolute != null -> am.setStreamVolume(audioStream, absolute, 0)
                        delta != null && delta > 0 ->
                            am.adjustStreamVolume(audioStream, AudioManager.ADJUST_RAISE, 0)
                        delta != null && delta < 0 ->
                            am.adjustStreamVolume(audioStream, AudioManager.ADJUST_LOWER, 0)
                    }

                    val current = am.getStreamVolume(audioStream)
                    val max = am.getStreamMaxVolume(audioStream)
                    result.success(mapOf("current" to current, "max" to max))
                }

                "getVolume" -> {
                    val am = getSystemService(AUDIO_SERVICE) as AudioManager
                    val current = am.getStreamVolume(AudioManager.STREAM_MUSIC)
                    val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    result.success(mapOf("current" to current, "max" to max))
                }

                // ── Wake word ("Exigir Orion") ────────────────────────────────
                "startWakeWord" -> {
                    ContextCompat.startForegroundService(
                        this, Intent(this, OrionWakeWordService::class.java)
                    )
                    result.success(true)
                }
                "stopWakeWord" -> {
                    stopService(Intent(this, OrionWakeWordService::class.java))
                    result.success(true)
                }
                "pauseWakeWord" -> {
                    OrionWakeWordService.pause()
                    result.success(true)
                }
                "resumeWakeWord" -> {
                    OrionWakeWordService.resume()
                    result.success(true)
                }

                // ── Atualização in-app ────────────────────────────────────────
                "canInstallPackages" -> {
                    val can = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                        packageManager.canRequestPackageInstalls() else true
                    result.success(can)
                }
                "openInstallPermissionSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }
                    result.success(true)
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("no_path", "caminho do APK ausente", null)
                    } else {
                        val file = File(path)
                        val uri = FileProvider.getUriForFile(
                            this, "$packageName.fileprovider", file
                        )
                        startActivity(
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(true)
                    }
                }

                else -> result.notImplemented()
            }
        }

        // Entrega o wake word do cold start depois que o app teve tempo de
        // registrar o handler Dart (initState da HomeScreen).
        if (pendingWakeWord) {
            pendingWakeWord = false
            val ch = methodChannel
            Handler(Looper.getMainLooper()).postDelayed({
                ch?.invokeMethod("wakeWord", null)
            }, 1500)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == OrionWakeWordService.ACTION_WAKE_WORD) {
            val ch = methodChannel
            if (ch != null) {
                ch.invokeMethod("wakeWord", null)
            } else {
                pendingWakeWord = true
            }
        }
    }
}
