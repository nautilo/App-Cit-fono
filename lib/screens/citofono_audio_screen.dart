import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as IO;

import '../config.dart';
import '../helpers/citofono_call_utils.dart';
import '../services/esp32_audio_bridge.dart';

class CitofonoAudioScreen extends StatefulWidget {
  final String miRut;
  final String rutDestino;
  final String room;
  final bool isCaller;
  final IO.Socket? socket;
  final String? callId;
  final bool initialSpeakerOn;

  const CitofonoAudioScreen({
    super.key,
    required this.miRut,
    required this.rutDestino,
    required this.room,
    required this.isCaller,
    this.socket,
    this.callId,
    this.initialSpeakerOn = true,
  });

  @override
  State<CitofonoAudioScreen> createState() => _CitofonoAudioScreenState();
}

class _CitofonoAudioScreenState extends State<CitofonoAudioScreen> {
  final Esp32AudioBridge _bridge = Esp32AudioBridge();

  IO.Socket? _socket;
  Timer? _statsTimer;
  Timer? _pollTimer;
  Timer? _handsetTimer;
  DateTime? _startedAt;

  String _status = 'Preparando llamada...';
  String? _callId;
  bool _ending = false;
  bool _audioStarted = false;
  bool _answered = false;
  bool _muted = false;
  bool _speakerOn = true;
  bool _physicalHandsetWasLifted = false;
  int? _lastHookSequence;
  bool _checkingHandset = false;

  bool get _esLlamadaAppAlCitofono => widget.isCaller && isCitofonoTarget(widget.rutDestino);
  bool get _esLlamadaDesdeCitofono => !widget.isCaller && isCitofonoAudioCall({
        'caller_rut': widget.rutDestino,
        'caller_dpto': widget.rutDestino,
        'target_rut': widget.room,
      });

  @override
  void initState() {
    super.initState();
    _callId = widget.callId;
    _speakerOn = widget.initialSpeakerOn;
    _physicalHandsetWasLifted = !widget.initialSpeakerOn;
    _setupSocket();
    _startHandsetMonitor();

    if (_esLlamadaAppAlCitofono) {
      _status = 'Llamando al citófono...';
      _startPollingCallState();
    } else {
      _answered = true;
      _notifyAppAnsweredIfNeeded();
      _startAudio();
    }

    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _setupSocket() {
    if (widget.socket != null) {
      _socket = widget.socket!;
    } else {
      _socket = IO.io(kBaseUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': false,
      });
      _socket!.onConnect((_) {
        if (widget.miRut.isNotEmpty) {
          _socket!.emit('register', {'room': widget.miRut});
        }
      });
      _socket!.connect();
    }

    _socket?.off('citofono-answered');
    _socket?.off('citofono-call-state');
    _socket?.off('citofono-timeout');
    _socket?.off('end-call');

    _socket?.on('citofono-answered', (data) {
      if (!_matchesCall(data)) return;
      _onRemoteAnswered();
    });

    _socket?.on('citofono-call-state', (data) {
      if (!_matchesCall(data)) return;
      final state = (data is Map ? data['state'] : '').toString();
      if (state == 'active') _onRemoteAnswered();
      if (state == 'ended') _finalizar(remoto: true, reason: 'remote_ended');
    });

    _socket?.on('citofono-timeout', (data) {
      if (!_matchesCall(data)) return;
      _finalizar(remoto: true, reason: 'timeout', showMessage: 'El citófono no contestó');
    });

    _socket?.on('end-call', (data) {
      if (data is Map && data['call_id'] != null && !_matchesCall(data)) return;
      _finalizar(remoto: true, reason: 'remote_ended', showMessage: 'La otra parte colgó');
    });

    _socket?.on('missed-call', (data) {
      if (data is Map && data['call_id'] != null && !_matchesCall(data)) return;
      _finalizar(remoto: true, reason: 'remote_ended', showMessage: 'La otra parte colgó');
    });
  }

  bool _matchesCall(dynamic data) {
    if (_callId == null || _callId!.isEmpty) return true;
    if (data is! Map) return true;
    final other = data['call_id']?.toString();
    return other == null || other.isEmpty || other == _callId;
  }

  Future<void> _notifyAppAnsweredIfNeeded() async {
    if (!_esLlamadaDesdeCitofono || _callId == null || _callId!.isEmpty) return;
    try {
      _socket?.emit('citofono-app-answer', {'call_id': _callId, 'rut': widget.miRut});
      await http.post(
        Uri.parse('$kBaseUrl/api/citofono/app-answer'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'call_id': _callId, 'rut': widget.miRut}),
      );
    } catch (_) {}
  }

  void _startHandsetMonitor() {
    _handsetTimer?.cancel();
    _handsetTimer = Timer.periodic(const Duration(milliseconds: 300), (_) => _checkHandsetState());
    _checkHandsetState();
  }

  Future<void> _checkHandsetState() async {
    if (_checkingHandset || _ending) return;
    _checkingHandset = true;

    try {
      final state = await Esp32AudioBridge.getHandsetState();
      final lifted = state['handsetLifted'] == true;
      final sequence = _readInt(state['hookSequence']);

      if (_lastHookSequence == null) {
        _lastHookSequence = sequence;
        if (lifted) {
          _physicalHandsetWasLifted = true;
          if (_speakerOn) {
            await _setSpeakerRoute(false, source: 'banana');
          }
        }
        return;
      }

      if (sequence == _lastHookSequence) return;
      _lastHookSequence = sequence;

      if (lifted) {
        _physicalHandsetWasLifted = true;
        await _setSpeakerRoute(false, source: 'banana');
      } else if (_physicalHandsetWasLifted && _answered && !_ending) {
        await _finalizar(reason: 'handset_hangup');
      }
    } catch (_) {
      // Si el equipo no informa hook físico, la llamada sigue funcionando con los botones en pantalla.
    } finally {
      _checkingHandset = false;
    }
  }

  int _readInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> _setSpeakerRoute(bool speakerOn, {String source = 'manual'}) async {
    final previous = _speakerOn;

    if (mounted) {
      setState(() {
        _speakerOn = speakerOn;
        if (_audioStarted && !_ending) {
          _status = 'Cambiando salida a ${speakerOn ? 'altavoces' : 'auricular'}...';
        }
      });
    } else {
      _speakerOn = speakerOn;
    }

    final ok = await _bridge.setUseSpeaker(speakerOn);
    if (!mounted || _ending || !_audioStarted) return;

    setState(() {
      if (ok) {
        final detalle = source == 'banana'
            ? 'Audio conectado · Auricular telefónico KT5-3C'
            : 'Audio conectado · ${_speakerOn ? 'Altavoz' : 'Auricular'}';
        _status = detalle;
      } else {
        _speakerOn = previous;
        _status = 'Android no aceptó esa salida de audio en este equipo.';
      }
    });
  }

  void _startPollingCallState() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_esLlamadaAppAlCitofono || _answered || _ending) return;
      try {
        final query = _callId == null ? '' : '?call_id=${Uri.encodeComponent(_callId!)}';
        final uri = Uri.parse('$kBaseUrl/api/citofono/state$query');
        final res = await http.get(uri).timeout(const Duration(seconds: 4));
        final data = jsonDecode(res.body);
        final call = data['call'];
        if (call is! Map) return;
        if (!_matchesCall(call)) return;
        final state = call['state']?.toString();
        if (state == 'active') {
          _onRemoteAnswered();
        } else if (state == 'ended') {
          _finalizar(remoto: true, reason: call['end_reason']?.toString() ?? 'ended');
        }
      } catch (_) {}
    });
  }

  void _onRemoteAnswered() {
    if (_answered || _ending) return;
    _answered = true;
    _pollTimer?.cancel();
    if (mounted) setState(() => _status = 'Citófono contestó. Conectando audio...');
    _startAudio();
  }

  Future<void> _startAudio() async {
    if (_audioStarted || _ending) return;
    _audioStarted = true;
    _startedAt = DateTime.now();

    try {
      await _bridge.setUseSpeaker(_speakerOn);
      await _bridge.start();
      _bridge.setMuted(_muted);
      await _bridge.setUseSpeaker(_speakerOn);
      if (!mounted) return;

      if (_bridge.playerFailed && _bridge.recorderFailed) {
        setState(() => _status = 'Este dispositivo no soporta el audio del citófono.');
      } else if (_bridge.playerFailed) {
        setState(() => _status = 'Micrófono activo, pero este dispositivo no reproduce audio del citófono.');
      } else if (_bridge.recorderFailed) {
        setState(() => _status = 'Escuchando citófono, pero el micrófono no inició en este dispositivo.');
      } else if (_bridge.playbackSampleRate == 48000) {
        setState(() => _status = 'Audio conectado en modo compatible 48 kHz · ${_speakerOn ? 'Altavoz' : 'Auricular'}');
      } else {
        setState(() => _status = 'Audio conectado · ${_speakerOn ? 'Altavoz' : 'Auricular'}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'No se pudo iniciar el audio del citófono: $e');
    }
  }

  int _durationSeconds() {
    final start = _startedAt;
    if (start == null) return 0;
    return DateTime.now().difference(start).inSeconds;
  }

  Future<void> _finalizar({bool remoto = false, String reason = 'finalizada', String? showMessage}) async {
    if (_ending) return;
    _ending = true;

    if (mounted) setState(() => _status = 'Finalizando...');

    _pollTimer?.cancel();
    _handsetTimer?.cancel();

    try {
      if (!remoto) {
        _socket?.emit('citofono-end-call', {
          'call_id': _callId,
          'room': widget.room,
          'rut': widget.miRut,
          'reason': reason,
          'estado': reason == 'rechazada' ? 'rechazada' : 'finalizada',
        });
      }
      _socket?.emit('end-call', {'room': widget.room, 'call_id': _callId});
      _socket?.emit('free-rut', {'rut': widget.miRut});
    } catch (_) {}

    if (!remoto) {
      try {
        await http.post(
          Uri.parse('$kBaseUrl/api/esp32/end-call'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'call_id': _callId,
            'room': widget.room,
            'rut_emisor': widget.isCaller ? widget.miRut : widget.rutDestino,
            'rut_receptor': widget.isCaller ? widget.rutDestino : widget.miRut,
            'tipo_llamada': 'audio',
            'estado': reason == 'rechazada' ? 'rechazada' : 'finalizada',
            'reason': reason,
            'duracion_segundos': _durationSeconds(),
          }),
        );
      } catch (_) {}
    }

    await _bridge.stop();

    if (mounted) {
      if (showMessage != null && showMessage.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(showMessage)));
      }
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _pollTimer?.cancel();
    _handsetTimer?.cancel();
    _socket?.off('citofono-answered');
    _socket?.off('citofono-call-state');
    _socket?.off('citofono-timeout');
    _socket?.off('end-call');
    _socket?.off('missed-call');
    if (widget.socket == null) {
      _socket?.dispose();
    }
    _bridge.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = widget.isCaller ? 'Llamando a ${widget.rutDestino}' : 'De ${widget.rutDestino}';
    final waitingForAnswer = _esLlamadaAppAlCitofono && !_answered;

    return Scaffold(
      backgroundColor: const Color(0xFF11111B),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF448AFF).withOpacity(0.18),
                  border: Border.all(color: waitingForAnswer ? Colors.orangeAccent : const Color(0xFF448AFF), width: 2),
                ),
                child: Icon(
                  waitingForAnswer ? Icons.notifications_active_rounded : Icons.doorbell_rounded,
                  color: waitingForAnswer ? Colors.orangeAccent : const Color(0xFF448AFF),
                  size: 58,
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Llamada de citófono',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _bridge.playerFailed ? Colors.orangeAccent : Colors.white70,
                  ),
                ),
              ),
              if (_bridge.playerFailed) ...[
                const SizedBox(height: 10),
                const Text(
                  'La tablet no logró abrir AudioTrack para PCM. La llamada sigue viva; prueba actualizar Android o usar otro equipo si no escuchas audio.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'CALL: ${_callId ?? '-'} · RX: ${_bridge.rxBytes} bytes · TX: ${_bridge.txBytes} bytes · PLAY: ${_bridge.playbackSampleRate} Hz',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              if (_bridge.droppedTxBytes > 0)
                Text(
                  'Audio atrasado descartado: ${_bridge.droppedTxBytes} bytes',
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
                ),
              const SizedBox(height: 42),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FloatingActionButton(
                    heroTag: 'route_citofono',
                    backgroundColor: _speakerOn ? const Color(0xFF448AFF) : const Color(0xFF2A2A3A),
                    onPressed: () => _setSpeakerRoute(!_speakerOn),
                    tooltip: _speakerOn ? 'Usar auricular telefónico' : 'Usar altavoz',
                    child: Icon(_speakerOn ? Icons.volume_up_rounded : Icons.phone_in_talk_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 20),
                  FloatingActionButton(
                    heroTag: 'mute_citofono',
                    backgroundColor: const Color(0xFF2A2A3A),
                    onPressed: waitingForAnswer
                        ? null
                        : () {
                            setState(() => _muted = !_muted);
                            _bridge.setMuted(_muted);
                          },
                    child: Icon(_muted ? Icons.mic_off : Icons.mic, color: Colors.white),
                  ),
                  const SizedBox(width: 28),
                  FloatingActionButton.large(
                    heroTag: 'end_citofono',
                    backgroundColor: const Color(0xFFFF5252),
                    onPressed: _finalizar,
                    child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 36),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                _speakerOn ? 'Salida: altavoces comunes' : 'Salida: auricular telefónico KT5-3C',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
