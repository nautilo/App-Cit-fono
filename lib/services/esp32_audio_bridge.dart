import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config.dart';

String _wsBaseUrl() {
  if (kBaseUrl.startsWith('https://')) {
    return kBaseUrl.replaceFirst('https://', 'wss://');
  }
  if (kBaseUrl.startsWith('http://')) {
    return kBaseUrl.replaceFirst('http://', 'ws://');
  }
  return 'wss://$kBaseUrl';
}

/// Puente de audio crudo compatible con el backend ESP32 tipo wsAudioServer.
///
/// Formato esperado por el ESP32:
/// - PCM16 mono
/// - 16 kHz (Sincronizado con hardware)
/// - little-endian
/// - binario crudo por WebSocket, sin JSON/base64/WebRTC
class Esp32AudioBridge {
  static const int sampleRate = 16000; // ¡Actualizado a 16kHz!
  static const int micCaptureSampleRate = 48000;
  static const int fallbackPlaybackSampleRate = 48000;
  static const int channels = 1;
  static const int bytesPerSample = 2;
  static const int frameMs = 20;
  
  // 640 bytes @ 16 kHz
  static const int txFrameBytes = sampleRate * bytesPerSample * frameMs ~/ 1000; 

  // Factor de remuestreo ahora es 3 (48000 / 16000)
  static const int micDownsampleFactor = micCaptureSampleRate ~/ sampleRate; 

  static const int maxQueuedBytes = txFrameBytes * 4;

  static const int micWarmupDiscardMs = 700;
  static const int rxWarmupDiscardMs = 250;

  // Límite duro: PCM16 mono 16 kHz = 32000 bytes/s.
  // Dejamos margen pequeño por jitter del Timer (aprox 8%).
  static const int maxTxBytesPerSecond = 34560; // ¡Límite actualizado!

  static const MethodChannel _nativeAudioTrack = MethodChannel('gladiator/citofono_audio_track');

  static Future<Map<String, dynamic>> getHandsetState() async {
    if (!Platform.isAndroid) {
      return <String, dynamic>{
        'handsetLifted': false,
        'headsetPlugged': false,
        'hookSequence': 0,
        'sdk': 0,
      };
    }

    try {
      final state = await _nativeAudioTrack.invokeMapMethod<String, dynamic>('getHandsetState');
      return Map<String, dynamic>.from(state ?? const <String, dynamic>{});
    } catch (e) {
      debugPrint('[CITOFONO_AUDIO] get handset state FAIL: $e');
      return <String, dynamic>{
        'handsetLifted': false,
        'headsetPlugged': false,
        'hookSequence': 0,
      };
    }
  }

  static Future<void> resetHandsetState() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeAudioTrack.invokeMethod<void>('resetHandsetState');
    } catch (e) {
      debugPrint('[CITOFONO_AUDIO] reset handset state FAIL: $e');
    }
  }

  FlutterSoundPlayer _player = FlutterSoundPlayer();
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();

  WebSocket? _rxSocket;
  WebSocket? _txSocket;
  StreamController<Uint8List>? _micStreamController;
  StreamSubscription<Uint8List>? _micSubscription;
  Timer? _txTimer;

  final Queue<int> _txQueue = Queue<int>();
  Uint8List _micDownsampleCarry = Uint8List(0);

  static Esp32AudioBridge? _activeBridge;

  bool _started = false;
  bool _playerOpened = false;
  bool _playerReady = false;
  bool _playerStarted = false;
  bool _playerFailed = false;
  bool _usingNativePlayer = false;
  bool _nativePlayerReady = false;
  bool _recorderOpened = false;
  bool _recorderStarted = false;
  bool _recorderFailed = false;
  bool _muted = false;
  bool _useSpeaker = true;
  int _playbackSampleRate = sampleRate;
  String? _playerError;
  String? _recorderError;

  int rxBytes = 0;
  int txBytes = 0;
  int droppedTxBytes = 0;
  int warmupDroppedTxBytes = 0;
  int resampledMicInputBytes = 0;
  int resampledMicOutputBytes = 0;
  int _txWindowStartMs = 0;
  int _txWindowBytes = 0;
  int _txWindowDropped = 0;
  int _micWarmupUntilMs = 0;
  int _rxWarmupUntilMs = 0;

  bool get playerReady => _playerReady;
  bool get playerFailed => _playerFailed;
  bool get recorderFailed => _recorderFailed;
  int get playbackSampleRate => _playbackSampleRate;
  String? get playerError => _playerError;
  String? get recorderError => _recorderError;
  bool get useSpeaker => _useSpeaker;

  Future<bool> setUseSpeaker(bool value) async {
    _useSpeaker = value;
    return _applyAudioRoute();
  }

  Future<bool> _applyAudioRoute() async {
    if (!Platform.isAndroid) return true;

    try {
      final routeInfo = await _nativeAudioTrack.invokeMapMethod<String, dynamic>(
        'setRoute',
        <String, dynamic>{'speakerOn': _useSpeaker},
      );
      debugPrint('[CITOFONO_AUDIO] route ${_useSpeaker ? 'speaker' : 'handset'} -> $routeInfo');

      final communicationResult = routeInfo?['communicationResult'];
      if (communicationResult == false) return false;
      return true;
    } catch (e, st) {
      debugPrint('[CITOFONO_AUDIO] route FAIL: $e');
      debugPrint('$st');
      return false;
    }
  }

  Future<void> _releaseAudioRoute() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeAudioTrack.invokeMethod<void>('releaseRoute');
    } catch (e) {
      debugPrint('[CITOFONO_AUDIO] release route FAIL: $e');
    }
  }

  void setMuted(bool value) {
    _muted = value;
    if (value) {
      _txQueue.clear();
    }
  }

  Future<void> start() async {
    if (_started) return;

    if (_activeBridge != null && _activeBridge != this) {
      await _activeBridge!.stop();
    }
    _activeBridge = this;

    _started = true;
    droppedTxBytes = 0;
    warmupDroppedTxBytes = 0;
    resampledMicInputBytes = 0;
    resampledMicOutputBytes = 0;
    _txQueue.clear();
    _micDownsampleCarry = Uint8List(0);
    final now = DateTime.now().millisecondsSinceEpoch;
    _micWarmupUntilMs = now + micWarmupDiscardMs;
    _rxWarmupUntilMs = now + rxWarmupDiscardMs;

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      throw Exception('Permiso de micrófono denegado');
    }

    await _applyAudioRoute();
    await _openSockets();
    await _openAudio();
  }

  Future<void> _openSockets() async {
    final base = _wsBaseUrl();

    _rxSocket = await WebSocket.connect('$base/browser_rx');
    _txSocket = await WebSocket.connect('$base/browser_tx');

    _rxSocket!.listen(
      (data) {
        if (data is List<int>) {
          final bytes = Uint8List.fromList(data);
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now < _rxWarmupUntilMs) {
            return;
          }
          rxBytes += bytes.length;
          _feedPlayer(bytes);
        }
      },
      onError: (e) => debugPrint('[CITOFONO_AUDIO] browser_rx error: $e'),
      onDone: () => debugPrint('[CITOFONO_AUDIO] browser_rx cerrado'),
      cancelOnError: true,
    );
  }

  Future<void> _openAudio() async {
    await _applyAudioRoute();
    await _startPlayerSafe();
    await _applyAudioRoute();
    await _startRecorderSafe();
    await _applyAudioRoute();

    _txTimer?.cancel();
    _txWindowStartMs = DateTime.now().millisecondsSinceEpoch;
    _txWindowBytes = 0;
    _txWindowDropped = 0;

    _txTimer = Timer.periodic(const Duration(milliseconds: frameMs), (_) {
      _flushOneTxFrame();
    });
  }

  Future<void> _startPlayerSafe() async {
    _playerReady = false;
    _playerStarted = false;
    _playerFailed = false;
    _usingNativePlayer = false;
    _nativePlayerReady = false;
    _playerError = null;
    _playbackSampleRate = sampleRate;

    if (Platform.isAndroid) {
      debugPrint('[CITOFONO_AUDIO] player start native AudioTrack 16000...');
      final native16 = await _tryStartNativePlayer(sampleRate);
      if (native16) {
        debugPrint('[CITOFONO_AUDIO] native AudioTrack 16000 OK');
        return;
      }

      debugPrint('[CITOFONO_AUDIO] retry native AudioTrack 48000...');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final native48 = await _tryStartNativePlayer(fallbackPlaybackSampleRate);
      if (native48) {
        _playbackSampleRate = fallbackPlaybackSampleRate;
        debugPrint('[CITOFONO_AUDIO] native AudioTrack 48000 OK');
        return;
      }
    }

    debugPrint('[CITOFONO_AUDIO] retry flutter_sound player 16000...');
    final ok16 = await _tryStartPlayer(sampleRate);
    if (ok16) {
      debugPrint('[CITOFONO_AUDIO] flutter_sound player 16000 OK');
      return;
    }

    debugPrint('[CITOFONO_AUDIO] retry flutter_sound player 48000...');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final ok48 = await _tryStartPlayer(fallbackPlaybackSampleRate);
    if (ok48) {
      _playbackSampleRate = fallbackPlaybackSampleRate;
      debugPrint('[CITOFONO_AUDIO] flutter_sound player 48000 OK');
      return;
    }

    _playerFailed = true;
    _playerReady = false;
    _playerStarted = false;
    _usingNativePlayer = false;
    _nativePlayerReady = false;
    _playerError ??= 'Este dispositivo no soporta reproducción PCM del citófono.';
    debugPrint('[CITOFONO_AUDIO] player disabled on this device: $_playerError');
  }

  Future<bool> _tryStartNativePlayer(int rate) async {
    await _safeClosePlayer();
    try {
      final ok = await _nativeAudioTrack.invokeMethod<bool>(
        'start',
        <String, dynamic>{'sampleRate': rate},
      );
      if (ok == true) {
        _usingNativePlayer = true;
        _nativePlayerReady = true;
        _playerReady = true;
        _playerStarted = true;
        _playerFailed = false;
        _playbackSampleRate = rate;
        _playerError = null;
        return true;
      }
      _playerError = 'Native AudioTrack no inició en $rate Hz';
      return false;
    } catch (e, st) {
      _playerError = e.toString();
      debugPrint('[CITOFONO_AUDIO] native AudioTrack $rate FAIL: $e');
      debugPrint('$st');
      try {
        await _nativeAudioTrack.invokeMethod<void>('stop');
      } catch (_) {}
      _usingNativePlayer = false;
      _nativePlayerReady = false;
      return false;
    }
  }

  Future<bool> _tryStartPlayer(int rate) async {
    await _safeClosePlayer();
    _player = FlutterSoundPlayer();
    _playerOpened = false;
    _playerReady = false;
    _playerStarted = false;

    try {
      await _player.openPlayer();
      _playerOpened = true;

      await _player.startPlayerFromStream(
        codec: Codec.pcm16,
        numChannels: channels,
        sampleRate: rate,
        interleaved: true,
        bufferSize: 2048,
      );

      _playerReady = true;
      _playerStarted = true;
      _playbackSampleRate = rate;
      return true;
    } catch (e, st) {
      _playerError = e.toString();
      debugPrint('[CITOFONO_AUDIO] player $rate FAIL: $e');
      debugPrint('$st');
      await _safeClosePlayer();
      return false;
    }
  }

  Future<void> _startRecorderSafe() async {
    _recorderOpened = false;
    _recorderStarted = false;
    _recorderFailed = false;
    _recorderError = null;

    try {
      await _recorder.openRecorder();
      _recorderOpened = true;

      _micStreamController = StreamController<Uint8List>();
      _micSubscription = _micStreamController!.stream.listen(_enqueueMicBytes);

      await _recorder.startRecorder(
        toStream: _micStreamController!.sink,
        codec: Codec.pcm16,
        numChannels: channels,
        sampleRate: micCaptureSampleRate,
      );
      _recorderStarted = true;
      debugPrint('[CITOFONO_AUDIO] recorder ${micCaptureSampleRate} Hz OK -> downsample a ${sampleRate} Hz');
    } catch (e, st) {
      _recorderFailed = true;
      _recorderError = e.toString();
      debugPrint('[CITOFONO_AUDIO] recorder FAIL: $e');
      debugPrint('$st');
      await _safeStopRecorder();
    }
  }

  void _feedPlayer(Uint8List bytes) {
    if (!_playerReady || _playerFailed || !_playerStarted) return;

    Uint8List payload = bytes;
    if (_playbackSampleRate == fallbackPlaybackSampleRate) {
      payload = _upsamplePcm16Mono16kTo48k(bytes); // Actualizado a 16k
    }

    if (_usingNativePlayer && _nativePlayerReady) {
      _nativeAudioTrack.invokeMethod<void>(
        'write',
        <String, dynamic>{'data': payload},
      ).catchError((Object e) {
        _playerFailed = true;
        _playerReady = false;
        _nativePlayerReady = false;
        _playerError = e.toString();
        debugPrint('[CITOFONO_AUDIO] native AudioTrack write FAIL: $e');
      });
      return;
    }

    try {
      final sink = _player.uint8ListSink;
      if (sink == null) return;

      const maxChunk = 2048;
      for (int offset = 0; offset < payload.length; offset += maxChunk) {
        final end = (offset + maxChunk > payload.length) ? payload.length : offset + maxChunk;
        sink.add(payload.sublist(offset, end));
      }
    } catch (e, st) {
      _playerFailed = true;
      _playerReady = false;
      _playerError = e.toString();
      debugPrint('[CITOFONO_AUDIO] player feed FAIL: $e');
      debugPrint('$st');
    }
  }

  // --- UPSAMPLING ACTUALIZADO PARA 16kHz -> 48kHz ---
  Uint8List _upsamplePcm16Mono16kTo48k(Uint8List input) {
    final usable = input.length - (input.length % 2);
    // 16 kHz -> 48 kHz = repetir cada muestra 3 veces.
    final output = Uint8List(usable * 3);
    int out = 0;

    for (int i = 0; i < usable; i += 2) {
      final lo = input[i];
      final hi = input[i + 1];
      for (int r = 0; r < 3; r++) {
        output[out++] = lo;
        output[out++] = hi;
      }
    }
    return output;
  }

  int _readPcm16Le(Uint8List data, int offset) {
    int v = data[offset] | (data[offset + 1] << 8);
    if ((v & 0x8000) != 0) v -= 0x10000;
    return v;
  }

  void _writePcm16Le(Uint8List data, int offset, int sample) {
    if (sample > 32767) sample = 32767;
    if (sample < -32768) sample = -32768;
    final v = sample < 0 ? sample + 0x10000 : sample;
    data[offset] = v & 0xFF;
    data[offset + 1] = (v >> 8) & 0xFF;
  }

  // --- DOWNSAMPLING ACTUALIZADO PARA 48kHz -> 16kHz ---
  Uint8List _downsampleMic48kTo16k(Uint8List bytes, int incoming) {
    Uint8List input;
    if (_micDownsampleCarry.isEmpty) {
      input = incoming == bytes.length ? bytes : bytes.sublist(0, incoming);
    } else {
      input = Uint8List(_micDownsampleCarry.length + incoming);
      input.setRange(0, _micDownsampleCarry.length, _micDownsampleCarry);
      input.setRange(_micDownsampleCarry.length, input.length, bytes.sublist(0, incoming));
    }

    const int inBytesPerOutSample = micDownsampleFactor * bytesPerSample; 
    final int consumable = input.length - (input.length % inBytesPerOutSample);
    final int carryLen = input.length - consumable;

    if (carryLen > 0) {
      _micDownsampleCarry = Uint8List(carryLen);
      _micDownsampleCarry.setRange(0, carryLen, input.sublist(consumable));
    } else {
      _micDownsampleCarry = Uint8List(0);
    }

    if (consumable <= 0) return Uint8List(0);

    final int outSamples = consumable ~/ inBytesPerOutSample;
    final output = Uint8List(outSamples * bytesPerSample);

    int out = 0;
    for (int pos = 0; pos < consumable; pos += inBytesPerOutSample) {
      int acc = 0;
      for (int k = 0; k < micDownsampleFactor; k++) {
        acc += _readPcm16Le(input, pos + k * bytesPerSample);
      }
      _writePcm16Le(output, out, acc ~/ micDownsampleFactor);
      out += bytesPerSample;
    }

    resampledMicInputBytes += consumable;
    resampledMicOutputBytes += output.length;
    return output;
  }

  void _enqueueMicBytes(Uint8List bytes) {
    if (_muted) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final incoming = bytes.length - (bytes.length % 2);
    if (incoming <= 0) return;

    if (now < _micWarmupUntilMs) {
      warmupDroppedTxBytes += incoming;
      _txQueue.clear();
      _micDownsampleCarry = Uint8List(0);
      return;
    }

    if (_micWarmupUntilMs != 0) {
      _txQueue.clear();
      _micDownsampleCarry = Uint8List(0);
      _micWarmupUntilMs = 0;
    }

    final downsampled = _downsampleMic48kTo16k(bytes, incoming);
    if (downsampled.isEmpty) return;

    int start = 0;
    if (downsampled.length > maxQueuedBytes) {
      start = downsampled.length - maxQueuedBytes;
      start -= start % 2;
      droppedTxBytes += start;
      _txWindowDropped += start;
    }

    final int bytesToAdd = downsampled.length - start;
    while (_txQueue.length + bytesToAdd > maxQueuedBytes && _txQueue.length >= 2) {
      _txQueue.removeFirst();
      _txQueue.removeFirst();
      droppedTxBytes += 2;
      _txWindowDropped += 2;
    }

    for (int i = start; i < downsampled.length; i++) {
      _txQueue.addLast(downsampled[i]);
    }
  }

  void _flushOneTxFrame() {
    final ws = _txSocket;
    if (ws == null || ws.readyState != WebSocket.open) return;
    if (!_recorderStarted || _recorderFailed) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_txWindowStartMs == 0 || now - _txWindowStartMs >= 1000) {
      debugPrint(
        'ESP32 browser_tx rate: ${_txWindowBytes} B/s, '
        'dropped/window: $_txWindowDropped, queue: ${_txQueue.length}, '
        'mic resample: $resampledMicInputBytes->$resampledMicOutputBytes B, '
        'warmup: $warmupDroppedTxBytes B',
      );
      _txWindowStartMs = now;
      _txWindowBytes = 0;
      _txWindowDropped = 0;
    }

    final frame = Uint8List(txFrameBytes);
    
    int bytesToExtract = _txQueue.length < txFrameBytes ? _txQueue.length : txFrameBytes;
    
    bytesToExtract -= bytesToExtract % 2;

    for (int i = 0; i < bytesToExtract; i++) {
      frame[i] = _txQueue.removeFirst();
    }

    if (_txWindowBytes + frame.length > maxTxBytesPerSecond) {
      droppedTxBytes += frame.length;
      _txWindowDropped += frame.length;
      return;
    }

    try {
      ws.add(frame);
      txBytes += frame.length;
      _txWindowBytes += frame.length;
    } catch (e) {
      debugPrint('[CITOFONO_AUDIO] browser_tx send error: $e');
    }
  }
  
  Future<void> _safeStopRecorder() async {
    if (_recorderStarted) {
      try {
        await _recorder.stopRecorder();
      } catch (_) {}
    }
    _recorderStarted = false;

    try {
      await _micSubscription?.cancel();
    } catch (_) {}
    _micSubscription = null;

    try {
      await _micStreamController?.close();
    } catch (_) {}
    _micStreamController = null;

    if (_recorderOpened) {
      try {
        await _recorder.closeRecorder();
      } catch (_) {}
    }
    _recorderOpened = false;
  }

  Future<void> _safeClosePlayer() async {
    if (_usingNativePlayer || _nativePlayerReady) {
      try {
        await _nativeAudioTrack.invokeMethod<void>('stop');
      } catch (_) {}
    }
    _usingNativePlayer = false;
    _nativePlayerReady = false;

    if (_playerStarted) {
      try {
        await _player.stopPlayer();
      } catch (_) {}
    }
    _playerStarted = false;
    _playerReady = false;

    if (_playerOpened) {
      try {
        await _player.closePlayer();
      } catch (_) {}
    }
    _playerOpened = false;
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    _txTimer?.cancel();
    _txTimer = null;

    await _safeStopRecorder();
    await _safeClosePlayer();

    _txQueue.clear();
    _micDownsampleCarry = Uint8List(0);

    try {
      await _rxSocket?.close();
    } catch (_) {}
    try {
      await _txSocket?.close();
    } catch (_) {}
    _rxSocket = null;
    _txSocket = null;

    await _releaseAudioRoute();

    if (_activeBridge == this) {
      _activeBridge = null;
    }
  }
}