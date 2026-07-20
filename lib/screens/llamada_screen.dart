import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import '../config.dart';

class LlamadaScreen extends StatefulWidget {
  final String room;
  final bool isCaller;
  final String tipo;
  final IO.Socket? socket;
  final String miRut;
  final String rutDestino; // RUT de la otra persona (el que NO soy yo)

  const LlamadaScreen({
    super.key,
    required this.room,
    required this.isCaller,
    required this.tipo,
    this.socket,
    required this.miRut,
    required this.rutDestino,
  });

  @override
  State<LlamadaScreen> createState() => _LlamadaScreenState();
}

class _LlamadaScreenState extends State<LlamadaScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  String _status = 'Conectando...';
  bool _callEnded = false;
  late IO.Socket _socket;
  Timer? _timeoutTimer;

  bool _speakerOn = true;
  bool _muted = false;

  void _toggleSpeaker() async {
    _speakerOn = !_speakerOn;
    if (_localStream != null) {
      await Helper.setSpeakerphoneOn(_speakerOn);
    }
    setState(() {});
  }

  void _toggleMute() {
    _muted = !_muted;
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = !_muted;
    });
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _setupSocket();
    _initCall();
    if (widget.isCaller) {
      _startTimeoutTimer();
    }
  }

  void _startTimeoutTimer() {
    _timeoutTimer = Timer(const Duration(seconds: 45), () {
      if (!_callEnded && _status != 'Llamada conectada') {
        _finalizar(remoto: false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Nadie contestó la llamada')),
          );
        }
      }
    });
  }

  void _setupSocket() {
    if (widget.socket != null) {
      _socket = widget.socket!;
    } else {
      // Venimos de Notificación Push
      _socket = IO.io(kBaseUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': false,
      });
      _socket.connect();
    }
  }

  Future<void> _initCall() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    await _startCall();
  }

  Future<Map<String, dynamic>> _getIceServers() async {
    try {
      final res = await http.get(Uri.parse('$kBaseUrl/twilio-ice'));
      final data = jsonDecode(res.body);
      if (data['iceServers'] != null) {
        final List servers = data['iceServers'];
        return {
          'iceServers': servers.map((s) {
            final Map<String, dynamic> server = {'urls': s['urls']};
            if (s['username'] != null) server['username'] = s['username'];
            if (s['credential'] != null) server['credential'] = s['credential'];
            return server;
          }).toList(),
        };
      }
    } catch (_) {}
    return {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    };
  }

  Future<void> _startCall() async {
    final iceConfig = await _getIceServers();

    _peerConnection = await createPeerConnection(iceConfig);

    _peerConnection!.onIceCandidate = (candidate) {
      _socket.emit('ice-candidate', {
        'room': widget.room,
        'candidate': candidate.toMap(),
      });
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        setState(() {
          _remoteRenderer.srcObject = event.streams[0];
          _status = 'Llamada conectada';
        });
      }
    };

    // Obtener cámara y micrófono
    final constraints = widget.tipo == 'audio'
        ? {'audio': true, 'video': false}
        : {
            'audio': true,
            'video': {
              'facingMode': 'user',
              'width': 640,
              'height': 480,
              'frameRate': 30,
            }
          };

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      _localRenderer.srcObject = _localStream;
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
      if (mounted) setState(() {}); // Renderizar el video local
      
      if (widget.tipo == 'audio') {
        Helper.setSpeakerphoneOn(_speakerOn);
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Error al acceder a la cámara: $e');
    }

    // Escuchar señales WebRTC
    _socket.on('offer', (data) async {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recibiendo Offer...')));
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(data['sdp']['sdp'], data['sdp']['type']),
      );
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);
      _socket.emit('answer', {'room': widget.room, 'sdp': answer.toMap()});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Answer enviado!')));
      if (mounted) setState(() => _status = 'Llamada conectada');
    });

    _socket.on('answer', (data) async {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recibiendo Answer...')));
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(data['sdp']['sdp'], data['sdp']['type']),
      );
      if (mounted) setState(() => _status = 'Llamada conectada');
    });

    _socket.on('ice-candidate', (data) async {
      try {
        final c = data['candidate'];
        await _peerConnection!.addCandidate(
          RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']),
        );
      } catch (_) {}
    });

    _socket.on('end-call', (_) => _finalizar(remoto: true));
    _socket.on('missed-call', (_) => _finalizar(remoto: true));
    _socket.on('busy', (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Llamada rechazada')),
        );
      }
      _finalizar(remoto: true);
    });

    // Unirse a la sala cuando el socket esté conectado
    void unirseSala() {
      if (widget.isCaller) {
        setState(() => _status = 'Esperando que contesten...');
        _socket.on('ready', (_) async {
          final offer = await _peerConnection!.createOffer();
          await _peerConnection!.setLocalDescription(offer);
          _socket.emit('offer', {'room': widget.room, 'sdp': offer.toMap()});
        });
      } else {
        setState(() => _status = 'Conectando video...');
      }
      _socket.emit('join-call', {'room': widget.room, 'mi_rut': widget.miRut});
      debugPrint('📡 Emitido join-call a la sala ${widget.room} con mi_rut ${widget.miRut}');
    }

    if (_socket.connected) {
      unirseSala();
    } else {
      _socket.onConnect((_) => unirseSala());
      _socket.onConnectError((e) {
        if (mounted) setState(() => _status = 'Error de socket: $e');
      });
    }
  }

  Future<void> _finalizar({bool remoto = false}) async {
    if (_callEnded) return;
    _callEnded = true;

    // SIEMPRE liberar MI rut cuando termine la llamada
    if (widget.miRut.isNotEmpty) {
      _socket.emit('free-rut', {'rut': widget.miRut});
    }

    if (!remoto) {
      _socket.emit('end-call', {'room': widget.room});
      if (widget.isCaller && _status != 'Llamada conectada') {
        // Emitir a la sala del destino para que se le cierre el modal y deje de sonar
        _socket.emit('end-call', {'room': widget.rutDestino});
        _socket.emit('missed-call', {
          'room': widget.rutDestino,
          'caller_rut': widget.miRut,
          'reason': 'cancelada'
        });
      }
    }

    _peerConnection?.close();
    _localStream?.getTracks().forEach((t) => t.stop());

    // Ambos lados guardan su propio registro (emisor y receptor son siempre correctos)
    try {
      await http.post(
        Uri.parse('$kBaseUrl/historial'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'rut_emisor': widget.isCaller ? widget.miRut : widget.rutDestino,
          'rut_receptor': widget.isCaller ? widget.rutDestino : widget.miRut,
          'tipo_llamada': widget.tipo,
          'estado': (widget.isCaller && _status != 'Llamada conectada') ? 'perdida' : 'finalizada',
          'duracion_segundos': 0,
        }),
      );
    } catch (_) {}

    if (mounted) {
      if (remoto) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('La otra persona colgó')),
        );
      }
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _socket.off('offer');
    _socket.off('answer');
    _socket.off('ice-candidate');
    _socket.off('end-call');
    _socket.off('missed-call');
    _socket.off('busy');
    _socket.off('ready');
    if (widget.socket == null) {
      // Solo matar el socket si lo creamos aquí
      _socket.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tipo == 'audio') {
      return _buildAudioUI();
    }
    return Scaffold(
      backgroundColor: const Color(0xFF11111B),
      body: Stack(
        children: [
          // Video remoto (pantalla completa)
          if (widget.tipo == 'video')
            Positioned.fill(
              child: RTCVideoView(
                _remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),

          // Resplandor azul
          Container(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF448AFF).withOpacity(0.25),
                  blurRadius: 80,
                  spreadRadius: 10,
                ),
              ],
            ),
          ),

          // Video local (esquina superior derecha)
          if (widget.tipo == 'video')
            Positioned(
              top: 50,
              right: 15,
              width: 110,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: RTCVideoView(
                  _localRenderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),

          // Estado de la llamada
          Positioned(
            bottom: 130,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _status,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ),
            ),
          ),

          // Botón de colgar
          Positioned(
            bottom: 50,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton.large(
                backgroundColor: const Color(0xFFff5252),
                onPressed: _finalizar,
                child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 36),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioUI() {
    final subtitle = widget.isCaller ? 'Llamando a ${widget.rutDestino}' : 'De ${widget.rutDestino}';
    final waitingForAnswer = widget.isCaller && _status != 'Llamada conectada';

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
                  waitingForAnswer ? Icons.notifications_active_rounded : Icons.person_rounded,
                  color: waitingForAnswer ? Colors.orangeAccent : const Color(0xFF448AFF),
                  size: 58,
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Llamada de audio',
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
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 42),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FloatingActionButton(
                    heroTag: 'route_app',
                    backgroundColor: _speakerOn ? const Color(0xFF448AFF) : const Color(0xFF2A2A3A),
                    onPressed: _toggleSpeaker,
                    tooltip: _speakerOn ? 'Usar auricular' : 'Usar altavoz',
                    child: Icon(_speakerOn ? Icons.volume_up_rounded : Icons.phone_in_talk_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 20),
                  FloatingActionButton(
                    heroTag: 'mute_app',
                    backgroundColor: const Color(0xFF2A2A3A),
                    onPressed: waitingForAnswer ? null : _toggleMute,
                    child: Icon(_muted ? Icons.mic_off : Icons.mic, color: Colors.white),
                  ),
                  const SizedBox(width: 28),
                  FloatingActionButton.large(
                    heroTag: 'end_app',
                    backgroundColor: const Color(0xFFFF5252),
                    onPressed: () => _finalizar(remoto: false),
                    child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 36),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                _speakerOn ? 'Salida: altavoces comunes' : 'Salida: auricular interno',
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
