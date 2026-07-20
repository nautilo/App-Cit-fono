package com.example.citofono

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.max

class MainActivity : FlutterActivity() {
    private val channelName = "gladiator/citofono_audio_track"
    private var audioTrack: AudioTrack? = null
    private var currentSampleRate: Int = 8000

    private var preferredSpeakerOn: Boolean = true
    private var previousAudioMode: Int? = null
    private var previousSpeakerphoneOn: Boolean? = null
    private var focusRequest: AudioFocusRequest? = null
    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { }

    private var handsetLifted: Boolean = false
    private var headsetPlugged: Boolean = false
    private var hookSequence: Int = 0
    private var hookReceiverRegistered: Boolean = false
    private val hookReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != Intent.ACTION_HEADSET_PLUG) return
            val plugged = intent.getIntExtra("state", 0) == 1
            updateHandsetLifted(plugged, "HEADSET_PLUG")
            headsetPlugged = plugged
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val rate = call.argument<Int>("sampleRate") ?: 8000
                        try {
                            applyAudioRoute(preferredSpeakerOn)
                            result.success(startAudioTrack(rate))
                        } catch (e: Exception) {
                            result.error("AUDIO_TRACK_START", e.message, null)
                        }
                    }
                    "write" -> {
                        val data = call.argument<ByteArray>("data")
                        if (data == null) {
                            result.success(0)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(writeAudio(data))
                        } catch (e: Exception) {
                            result.error("AUDIO_TRACK_WRITE", e.message, null)
                        }
                    }
                    "setRoute" -> {
                        val speakerOn = call.argument<Boolean>("speakerOn") ?: true
                        try {
                            result.success(applyAudioRoute(speakerOn))
                        } catch (e: Exception) {
                            result.error("AUDIO_ROUTE", e.message, null)
                        }
                    }
                    "getRoute" -> {
                        try {
                            result.success(buildRouteInfo(null, null, null))
                        } catch (e: Exception) {
                            result.error("AUDIO_ROUTE_INFO", e.message, null)
                        }
                    }
                    "getHandsetState" -> {
                        try {
                            result.success(buildHandsetState())
                        } catch (e: Exception) {
                            result.error("HANDSET_STATE", e.message, null)
                        }
                    }
                    "resetHandsetState" -> {
                        try {
                            handsetLifted = false
                            headsetPlugged = false
                            hookSequence++
                            result.success(buildHandsetState())
                        } catch (e: Exception) {
                            result.error("HANDSET_RESET", e.message, null)
                        }
                    }
                    "releaseRoute" -> {
                        try {
                            releaseAudioRoute()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("AUDIO_ROUTE_RELEASE", e.message, null)
                        }
                    }
                    "stop" -> {
                        stopAudioTrack()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        registerHookReceiver()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_UP && event.repeatCount == 0) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_CALL -> updateHandsetLifted(true, "KEYCODE_CALL")
                KeyEvent.KEYCODE_ENDCALL -> updateHandsetLifted(false, "KEYCODE_ENDCALL")
                KeyEvent.KEYCODE_HEADSETHOOK,
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                KeyEvent.KEYCODE_MEDIA_PLAY -> toggleHandsetLifted("KEYCODE_${event.keyCode}")
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun registerHookReceiver() {
        if (hookReceiverRegistered) return
        try {
            val filter = IntentFilter(Intent.ACTION_HEADSET_PLUG)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(hookReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(hookReceiver, filter)
            }
            hookReceiverRegistered = true
        } catch (_: Exception) {}
    }

    private fun unregisterHookReceiver() {
        if (!hookReceiverRegistered) return
        try {
            unregisterReceiver(hookReceiver)
        } catch (_: Exception) {}
        hookReceiverRegistered = false
    }

    private fun updateHandsetLifted(lifted: Boolean, source: String) {
        if (handsetLifted != lifted) {
            handsetLifted = lifted
        }
        hookSequence++
    }

    private fun toggleHandsetLifted(source: String) {
        handsetLifted = !handsetLifted
        hookSequence++
    }

    private fun buildHandsetState(): Map<String, Any?> {
        return mapOf(
            "handsetLifted" to handsetLifted,
            "headsetPlugged" to headsetPlugged,
            "hookSequence" to hookSequence,
            "sdk" to Build.VERSION.SDK_INT
        )
    }

    private fun audioManager(): AudioManager {
        return getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    private fun requestCommunicationFocus(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val existing = focusRequest
            if (existing != null) {
                am.requestAudioFocus(existing)
                return
            }

            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAcceptsDelayedFocusGain(false)
                .setWillPauseWhenDucked(false)
                .setOnAudioFocusChangeListener(audioFocusChangeListener)
                .build()
            focusRequest = request
            am.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                audioFocusChangeListener,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
            )
        }
    }

    private fun abandonCommunicationFocus(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(audioFocusChangeListener)
        }
    }

    private fun applyAudioRoute(speakerOn: Boolean): Map<String, Any?> {
        val am = audioManager()
        preferredSpeakerOn = speakerOn

        if (previousAudioMode == null) previousAudioMode = am.mode
        if (previousSpeakerphoneOn == null) {
            @Suppress("DEPRECATION")
            previousSpeakerphoneOn = am.isSpeakerphoneOn
        }

        requestCommunicationFocus(am)
        am.mode = AudioManager.MODE_IN_COMMUNICATION

        var selectedDevice: AudioDeviceInfo? = null
        var communicationResult: Boolean? = null
        var preferredDeviceResult: Boolean? = null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            selectedDevice = findCommunicationOutput(am, speakerOn)
            if (selectedDevice != null) {
                communicationResult = am.setCommunicationDevice(selectedDevice)
            } else if (speakerOn) {
                communicationResult = false
            } else {
                // Para volver al auricular/receptor interno en equipos tipo teléfono,
                // limpiar la selección suele devolver la ruta por defecto del HAL.
                am.clearCommunicationDevice()
                communicationResult = true
            }
        }

        // Compatibilidad con Android <= 11 y con HALs de equipos tipo desk phone que
        // aún respetan el flag legacy aunque setCommunicationDevice exista.
        @Suppress("DEPRECATION")
        am.isSpeakerphoneOn = speakerOn

        preferredDeviceResult = applyPreferredDeviceToNativeTrack(selectedDevice, speakerOn)

        return buildRouteInfo(communicationResult, preferredDeviceResult, selectedDevice)
    }

    private fun releaseAudioRoute() {
        val am = audioManager()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.clearCommunicationDevice()
        }

        previousSpeakerphoneOn?.let {
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = it
        }

        previousAudioMode?.let {
            am.mode = it
        } ?: run {
            am.mode = AudioManager.MODE_NORMAL
        }

        abandonCommunicationFocus(am)
        previousSpeakerphoneOn = null
        previousAudioMode = null
    }

    private fun findCommunicationOutput(am: AudioManager, speakerOn: Boolean): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null

        val devices = am.availableCommunicationDevices.filter { it.isSink }
        val wantedTypes = if (speakerOn) {
            intArrayOf(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
        } else {
            intArrayOf(
                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES
            )
        }

        for (type in wantedTypes) {
            val match = devices.firstOrNull { it.type == type }
            if (match != null) return match
        }

        return null
    }

    private fun applyPreferredDeviceToNativeTrack(
        selectedDevice: AudioDeviceInfo?,
        speakerOn: Boolean
    ): Boolean? {
        val track = audioTrack ?: return null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null

        val device = selectedDevice ?: findOutputDeviceForAudioTrack(speakerOn)
        return if (device != null) {
            track.setPreferredDevice(device)
        } else {
            track.setPreferredDevice(null)
        }
    }

    private fun findOutputDeviceForAudioTrack(speakerOn: Boolean): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null

        val devices = audioManager().getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter { it.isSink }
        val wantedTypes = if (speakerOn) {
            intArrayOf(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
        } else {
            intArrayOf(
                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES
            )
        }

        for (type in wantedTypes) {
            val match = devices.firstOrNull { it.type == type }
            if (match != null) return match
        }

        return null
    }

    private fun buildRouteInfo(
        communicationResult: Boolean?,
        preferredDeviceResult: Boolean?,
        selectedDevice: AudioDeviceInfo?
    ): Map<String, Any?> {
        val am = audioManager()

        val communicationDevice = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.communicationDevice
        } else {
            null
        }

        val routedDevice = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            audioTrack?.routedDevice
        } else {
            null
        }

        val availableCommunicationDevices = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.availableCommunicationDevices
                .filter { it.isSink }
                .joinToString(separator = " | ") { deviceLabel(it) }
        } else {
            ""
        }

        val outputDevices = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .filter { it.isSink }
                .joinToString(separator = " | ") { deviceLabel(it) }
        } else {
            ""
        }

        @Suppress("DEPRECATION")
        val speakerphoneFlag = am.isSpeakerphoneOn

        return mapOf(
            "speakerOn" to preferredSpeakerOn,
            "mode" to am.mode,
            "isSpeakerphoneOn" to speakerphoneFlag,
            "communicationResult" to communicationResult,
            "preferredDeviceResult" to preferredDeviceResult,
            "selectedDevice" to selectedDevice?.let { deviceLabel(it) },
            "communicationDevice" to communicationDevice?.let { deviceLabel(it) },
            "nativeTrackRoutedDevice" to routedDevice?.let { deviceLabel(it) },
            "availableCommunicationDevices" to availableCommunicationDevices,
            "outputDevices" to outputDevices,
            "sdk" to Build.VERSION.SDK_INT
        )
    }

    private fun deviceLabel(device: AudioDeviceInfo): String {
        val name = device.productName?.toString()?.takeIf { it.isNotBlank() } ?: "sin_nombre"
        return "${device.type}:$name"
    }

    private fun startAudioTrack(sampleRate: Int): Boolean {
        stopAudioTrack()
        currentSampleRate = sampleRate

        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )

        if (minBuffer <= 0) {
            throw IllegalStateException("getMinBufferSize failed for $sampleRate Hz: $minBuffer")
        }

        val bufferSize = max(minBuffer * 2, sampleRate / 10 * 2)

        val track = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(bufferSize)
                .build()
        } else {
            @Suppress("DEPRECATION")
            AudioTrack(
                AudioManager.STREAM_VOICE_CALL,
                sampleRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize,
                AudioTrack.MODE_STREAM
            )
        }

        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            throw IllegalStateException("AudioTrack not initialized for $sampleRate Hz")
        }

        audioTrack = track
        applyAudioRoute(preferredSpeakerOn)
        track.play()
        return true
    }

    private fun writeAudio(data: ByteArray): Int {
        val track = audioTrack ?: return -1
        if (track.state != AudioTrack.STATE_INITIALIZED) return -2

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            track.write(data, 0, data.size, AudioTrack.WRITE_NON_BLOCKING)
        } else {
            track.write(data, 0, data.size)
        }
    }

    private fun stopAudioTrack() {
        val track = audioTrack
        audioTrack = null
        if (track != null) {
            try {
                if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    track.pause()
                    track.flush()
                }
            } catch (_: Exception) {}
            try {
                track.release()
            } catch (_: Exception) {}
        }
    }

    override fun onDestroy() {
        stopAudioTrack()
        unregisterHookReceiver()
        try {
            releaseAudioRoute()
        } catch (_: Exception) {}
        super.onDestroy()
    }
}
