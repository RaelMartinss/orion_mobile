package br.com.orion.mobile

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

class OrionWakeWordService : Service() {

    companion object {
        const val ACTION_WAKE_WORD = "br.com.orion.mobile.WAKE_WORD"
        private const val CHANNEL_ID = "orion_listener"
        private const val NOTIF_ID = 42
        var isRunning = false
        var isPaused = false

        // Chamado pelo app antes de usar o mic
        fun pause() {
            isPaused = true
            instance?.stopListeningNow()
        }

        // Chamado pelo app quando libera o mic
        fun resume() {
            isPaused = false
            instance?.scheduleRestart(500L)
        }

        private var instance: OrionWakeWordService? = null
    }

    private var speechRecognizer: SpeechRecognizer? = null
    private val handler = Handler(Looper.getMainLooper())
    private var restarting = false
    private var wakeWordTriggered = false

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        instance = this
        createNotificationChannel()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIF_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                )
            } else {
                startForeground(NOTIF_ID, buildNotification())
            }
        } catch (_: Exception) {
            // Sem permissão de mic, início em background bloqueado, etc.
            isRunning = false
            instance = null
            stopSelf()
            return
        }
        startListening()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY // reinicia automaticamente se o sistema matar
    }

    override fun onDestroy() {
        isRunning = false
        instance = null
        speechRecognizer?.destroy()
        speechRecognizer = null
        super.onDestroy()
    }

    fun stopListeningNow() {
        handler.removeCallbacksAndMessages(null)
        restarting = false
        speechRecognizer?.stopListening()
        speechRecognizer?.destroy()
        speechRecognizer = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Orion Listener",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Aguardando comando de voz"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Orion")
            .setContentText("Aguardando 'Orion'...")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    private fun startListening() {
        if (isPaused) return
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            scheduleRestart(5000L)
            return
        }

        wakeWordTriggered = false
        speechRecognizer?.destroy()
        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this)
        speechRecognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}

            override fun onPartialResults(partialResults: Bundle?) {
                if (wakeWordTriggered) return
                val matches = partialResults
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                if (matches?.any { containsWakeWord(it) } == true) {
                    onWakeWordDetected()
                }
            }

            override fun onResults(results: Bundle?) {
                if (!wakeWordTriggered) {
                    val matches = results
                        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    if (matches?.any { containsWakeWord(it) } == true) {
                        onWakeWordDetected()
                        return
                    }
                }
                // Pausa 800ms entre bursts — reduz conflito com STT do app
                scheduleRestart(800L)
            }

            override fun onError(error: Int) {
                val delay = when (error) {
                    SpeechRecognizer.ERROR_NO_MATCH,
                    SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> 800L
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> 1500L
                    else -> 800L
                }
                scheduleRestart(delay)
            }
        })

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "pt-BR")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 2000L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1500L)
        }

        try {
            speechRecognizer?.startListening(intent)
        } catch (e: Exception) {
            scheduleRestart(1000L)
        }
    }

    private fun containsWakeWord(text: String): Boolean {
        val lower = text.lowercase().trim()
        return lower.contains("orion") || lower.contains("órion") || lower == "lion"
    }

    private fun onWakeWordDetected() {
        wakeWordTriggered = true
        android.util.Log.d("OrionWakeWord", "Wake word detectado!")

        // Abre o app com a flag de wake word
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            action = ACTION_WAKE_WORD
        }
        startActivity(launch)

        // Reinicia a escuta após a interação (delay maior para não conflitar com STT do app)
        scheduleRestart(5000L)
    }

    private fun scheduleRestart(delay: Long) {
        if (restarting) return
        restarting = true
        handler.postDelayed({
            restarting = false
            startListening()
        }, delay)
    }
}
