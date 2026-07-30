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

/// Puente de audio crudo compatible con el backend ESP32.
class Esp32AudioBridge {
  static const int sampleRate = 16000;
  static const int micCaptureSampleRate = 48000;
  static const int fallbackPlaybackSampleRate = 48000;
  static const int channels = 1;
  static const int bytesPerSample = 2;
  static const int frameMs = 20;
  
  static const int txFrameBytes = sampleRate * bytesPerSample * frameMs ~/ 1000; // 640 bytes

  static const int micDownsampleFactor = micCaptureSampleRate ~/ sampleRate; 

  // RING BUFFER ESTRICTO (Petición del agente): Máximo 2 frames (40ms / 1280 bytes)
  // Si la red se pone lenta, bota el audio viejo para mantener el tiempo real.
  static const int maxQueuedBytes = txFrameBytes * 2;

  // Jitter Buffer RX: Acumular mínimo 3 frames (1920 bytes) antes de inyectar a iOS.
  static const int rxJitterThreshold = txFrameBytes * 3; 

  static const int micWarmupDiscardMs = 700;
  static const int rxWarmupDiscardMs = 250;
  static const int maxTxBytesPerSecond = 34560;

  static const MethodChannel _nativeAudioTrack = MethodChannel('gladiator/citofono_audio_track');

  static Future<Map<String, dynamic>> getHandsetState() async {
    if (!Platform.isAndroid) return <String, dynamic>{'handsetLifted': false, 'headsetPlugged': false, 'hookSequence': 0};
    try {
      final state = await _nativeAudioTrack.invokeMapMethod<String, dynamic>('getHandsetState');
      return Map<String, dynamic>.from(state ?? const <String, dynamic>{});
    } catch (e) {
      return <String, dynamic>{'handsetLifted': false, 'headsetPlugged': false, 'hookSequence': 0};
    }
  }

  // MÉTODO RESTAURADO PARA CONSERJE Y RESIDENTE
  static Future<void> resetHandsetState() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeAudioTrack.invokeMethod<void>('resetHandsetState');
    } catch (_) {}
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
  
  final List<int> _rxJitterBuffer = [];
  bool _rxBuffering = true;

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

  int rxBytes = 0;
  int txBytes = 0;
  int droppedTxBytes = 0;
  int resampledMicInputBytes = 0;
  int resampledMicOutputBytes = 0;
  int _micWarmupUntilMs = 0;
  int _rxWarmupUntilMs = 0;

  // GETTERS RESTAURADOS PARA LA UI
  bool get playerReady => _playerReady;
  bool get playerFailed => _playerFailed;
  bool get recorderFailed => _recorderFailed;
  int get playbackSampleRate => _playbackSampleRate;
  bool get useSpeaker => _useSpeaker;

  Future<bool> setUseSpeaker(bool value) async {
    _useSpeaker = value;
    return _applyAudioRoute();
  }

  Future<bool> _applyAudioRoute() async {
    if (!Platform.isAndroid) return true;
    try {
      final routeInfo = await _nativeAudioTrack.invokeMapMethod<String, dynamic>('setRoute', <String, dynamic>{'speakerOn': _useSpeaker});
      return routeInfo?['communicationResult'] != false;
    } catch (_) { return false; }
  }

  Future<void> _releaseAudioRoute() async {
    if (!Platform.isAndroid) return;
    try { await _nativeAudioTrack.invokeMethod<void>('releaseRoute'); } catch (_) {}
  }

  void setMuted(bool value) {
    _muted = value;
    if (value) _txQueue.clear();
  }

  Future<void> start() async {
    if (_started) return;
    if (_activeBridge != null && _activeBridge != this) await _activeBridge!.stop();
    _activeBridge = this;
    _started = true;
    droppedTxBytes = 0;
    _txQueue.clear();
    _rxJitterBuffer.clear();
    _rxBuffering = true;
    _micDownsampleCarry = Uint8List(0);
    
    final now = DateTime.now().millisecondsSinceEpoch;
    _micWarmupUntilMs = now + micWarmupDiscardMs;
    _rxWarmupUntilMs = now + rxWarmupDiscardMs;

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) throw Exception('Permiso denegado');

    await _applyAudioRoute();
    await _openSockets();
    await _openAudio();
  }

  Future<void> _openSockets() async {
    final base = _wsBaseUrl();
    _rxSocket = await WebSocket.connect('$base/browser_rx');
    _txSocket = await WebSocket.connect('$base/browser_tx');

    _rxSocket!.listen((data) {
      if (data is List<int>) {
        final bytes = Uint8List.fromList(data);
        if (DateTime.now().millisecondsSinceEpoch < _rxWarmupUntilMs) return;
        rxBytes += bytes.length;
        _feedPlayer(bytes);
      }
    }, cancelOnError: true);
  }

  Future<void> _openAudio() async {
    await _applyAudioRoute();
    await _startPlayerSafe();
    await _startRecorderSafe();
    
    // Vaciado súper rápido (10ms) con bucle While para evitar atascos de Timer.
    _txTimer?.cancel();
    _txTimer = Timer.periodic(const Duration(milliseconds: 10), (_) => _flushTxFrames());
  }

  Future<void> _startPlayerSafe() async {
    _playerReady = false;
    _playerStarted = false;
    _playerFailed = false;
    _usingNativePlayer = false;
    _nativePlayerReady = false;
    _playbackSampleRate = sampleRate;

    if (Platform.isAndroid) {
      if (await _tryStartNativePlayer(sampleRate)) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (await _tryStartNativePlayer(fallbackPlaybackSampleRate)) {
        _playbackSampleRate = fallbackPlaybackSampleRate;
        return;
      }
    }

    if (await _tryStartPlayer(sampleRate)) return;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (await _tryStartPlayer(fallbackPlaybackSampleRate)) {
      _playbackSampleRate = fallbackPlaybackSampleRate;
      return;
    }
    _playerFailed = true;
  }

  Future<bool> _tryStartNativePlayer(int rate) async {
    await _safeClosePlayer();
    try {
      final ok = await _nativeAudioTrack.invokeMethod<bool>('start', <String, dynamic>{'sampleRate': rate});
      if (ok == true) {
        _usingNativePlayer = true;
        _nativePlayerReady = true;
        _playerReady = true;
        _playerStarted = true;
        _playbackSampleRate = rate;
        return true;
      }
      return false;
    } catch (_) { return false; }
  }

  Future<bool> _tryStartPlayer(int rate) async {
    await _safeClosePlayer();
    _player = FlutterSoundPlayer();
    try {
      await _player.openPlayer();
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
    } catch (e) {
      await _safeClosePlayer();
      return false;
    }
  }

  Future<void> _startRecorderSafe() async {
    _recorderFailed = false;
    try {
      await _recorder.openRecorder();
      _micStreamController = StreamController<Uint8List>();
      _micSubscription = _micStreamController!.stream.listen(_enqueueMicBytes);
      await _recorder.startRecorder(
        toStream: _micStreamController!.sink,
        codec: Codec.pcm16,
        numChannels: channels,
        sampleRate: micCaptureSampleRate,
      );
      _recorderStarted = true;
    } catch (e) {
      _recorderFailed = true;
      await _safeStopRecorder();
    }
  }

  void _feedPlayer(Uint8List bytes) {
    if (!_playerReady || _playerFailed || !_playerStarted) return;
    if (_rxBuffering) {
      _rxJitterBuffer.addAll(bytes);
      if (_rxJitterBuffer.length >= rxJitterThreshold) {
        _rxBuffering = false;
        _writeToPlayerSink(Uint8List.fromList(_rxJitterBuffer));
        _rxJitterBuffer.clear();
      }
      return;
    }
    _writeToPlayerSink(bytes);
  }

  void _writeToPlayerSink(Uint8List bytes) {
    Uint8List payload = bytes;
    if (_playbackSampleRate == fallbackPlaybackSampleRate) payload = _upsamplePcm16Mono16kTo48k(bytes); 

    if (_usingNativePlayer && _nativePlayerReady) {
      _nativeAudioTrack.invokeMethod<void>('write', <String, dynamic>{'data': payload}).catchError((_) {
        _playerFailed = true;
        _playerReady = false;
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
    } catch (_) { _playerFailed = true; }
  }

  Uint8List _upsamplePcm16Mono16kTo48k(Uint8List input) {
    final usable = input.length - (input.length % 2);
    final output = Uint8List(usable * 3);
    int out = 0;
    for (int i = 0; i < usable; i += 2) {
      final lo = input[i];
      final hi = input[i + 1];
      for (int r = 0; r < 3; r++) { output[out++] = lo; output[out++] = hi; }
    }
    return output;
  }

  int _readPcm16Le(Uint8List data, int offset) {
    int v = data[offset] | (data[offset + 1] << 8);
    return ((v & 0x8000) != 0) ? v - 0x10000 : v;
  }

  void _writePcm16Le(Uint8List data, int offset, int sample) {
    if (sample > 32767) sample = 32767;
    if (sample < -32768) sample = -32768;
    final v = sample < 0 ? sample + 0x10000 : sample;
    data[offset] = v & 0xFF;
    data[offset + 1] = (v >> 8) & 0xFF;
  }

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
    final output = Uint8List((consumable ~/ inBytesPerOutSample) * bytesPerSample);
    int out = 0;
    for (int pos = 0; pos < consumable; pos += inBytesPerOutSample) {
      int acc = 0;
      for (int k = 0; k < micDownsampleFactor; k++) acc += _readPcm16Le(input, pos + k * bytesPerSample);
      _writePcm16Le(output, out, acc ~/ micDownsampleFactor);
      out += bytesPerSample;
    }
    return output;
  }

  void _enqueueMicBytes(Uint8List bytes) {
    if (_muted) return;
    final incoming = bytes.length - (bytes.length % 2);
    if (incoming <= 0) return;

    if (DateTime.now().millisecondsSinceEpoch < _micWarmupUntilMs) {
      _txQueue.clear();
      return;
    }

    final downsampled = _downsampleMic48kTo16k(bytes, incoming);
    if (downsampled.isEmpty) return;

    // Descarte proactivo exacto como lo pidió el agente (Ring Buffer)
    int start = 0;
    if (downsampled.length > maxQueuedBytes) {
      start = downsampled.length - maxQueuedBytes;
      start -= start % 2;
      droppedTxBytes += start;
    }

    final int bytesToAdd = downsampled.length - start;
    while (_txQueue.length + bytesToAdd > maxQueuedBytes && _txQueue.length >= 2) {
      _txQueue.removeFirst();
      _txQueue.removeFirst();
      droppedTxBytes += 2;
    }

    for (int i = start; i < downsampled.length; i++) _txQueue.addLast(downsampled[i]);
  }

  void _flushTxFrames() {
    final ws = _txSocket;
    if (ws == null || ws.readyState != WebSocket.open || !_recorderStarted) return;
    
    // Vaciado intensivo: Drena TODOS los paquetes acumulados de inmediato.
    while (_txQueue.length >= txFrameBytes) {
      final frame = Uint8List(txFrameBytes);
      for (int i = 0; i < txFrameBytes; i++) frame[i] = _txQueue.removeFirst();
      try {
        ws.add(frame);
        txBytes += frame.length;
      } catch (_) {}
    }
  }
  
  Future<void> _safeStopRecorder() async {
    _recorderStarted = false;
    try { await _recorder.stopRecorder(); } catch (_) {}
    try { await _micSubscription?.cancel(); } catch (_) {}
    try { await _micStreamController?.close(); } catch (_) {}
    try { await _recorder.closeRecorder(); } catch (_) {}
  }

  Future<void> _safeClosePlayer() async {
    _usingNativePlayer = false;
    _nativePlayerReady = false;
    _playerStarted = false;
    _playerReady = false;
    try { await _nativeAudioTrack.invokeMethod<void>('stop'); } catch (_) {}
    try { await _player.stopPlayer(); } catch (_) {}
    try { await _player.closePlayer(); } catch (_) {}
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _txTimer?.cancel();
    
    await _safeStopRecorder();
    await _safeClosePlayer();

    _txQueue.clear();
    _rxJitterBuffer.clear();
    _micDownsampleCarry = Uint8List(0);

    try { await _rxSocket?.close(); } catch (_) {}
    try { await _txSocket?.close(); } catch (_) {}
    await _releaseAudioRoute();
    if (_activeBridge == this) _activeBridge = null;
  }
}