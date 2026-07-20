import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import '../config.dart';
import 'llamada_screen.dart';
import 'citofono_audio_screen.dart';
import '../helpers/citofono_call_utils.dart';
import '../helpers/call_notifications.dart';
import 'login_screen.dart';
import '../widgets/directorio_modal.dart';
import '../widgets/historial_modal.dart';
import '../widgets/mensajes_modal.dart';
import '../helpers/message_navigation.dart';
import '../services/esp32_audio_bridge.dart';

class ResidenteScreen extends StatefulWidget {
  const ResidenteScreen({super.key});

  @override
  State<ResidenteScreen> createState() => _ResidenteScreenState();
}

class _ResidenteScreenState extends State<ResidenteScreen> {
  String miRut = '';
  String miNombre = '';
  String miDpto = '';
  late IO.Socket socket;
  Set<String> rutosOcupados = {};
  bool _socketConectado = false;
  final _ringtonePlayer = FlutterRingtonePlayer();
  bool _dialogoEntranteAbierto = false;

  void _tocarTono() => _ringtonePlayer.playRingtone();
  void _detenerTono() => _ringtonePlayer.stop();

  @override
  void initState() {
    super.initState();
    _cargarSesion();
  }

  Future<void> _cargarSesion() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      miRut = prefs.getString('rut') ?? '';
      miNombre = prefs.getString('nombre') ?? '';
      miDpto = prefs.getString('dpto') ?? '';
    });
    _conectarSocket();
    _abrirMensajesSiPendiente();
  }


  Future<void> _abrirMensajesSiPendiente() async {
    final prefs = await SharedPreferences.getInstance();
    final pendiente = prefs.getBool(kOpenMessagesPendingKey) ?? false;
    if (!pendiente || miRut.isEmpty) return;

    await prefs.setBool(kOpenMessagesPendingKey, false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _abrirMensajes();
    });
  }

  void _conectarSocket() {
    socket = IO.io(kBaseUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
    });

    socket.onConnect((_) {
      if (!mounted) return;
      setState(() => _socketConectado = true);
      socket.emit('register', {'room': miRut});
    });

    socket.onDisconnect((_) {
      if (!mounted) return;
      setState(() => _socketConectado = false);
    });

    socket.onConnectError((e) {
      if (!mounted) return;
      setState(() => _socketConectado = false);
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF222233),
          title: const Text('⚠️ Error de conexión (Socket)', style: TextStyle(color: Colors.orange)),
          content: Text('No se pudo conectar a $kBaseUrl\n\nDetalle: $e', style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK', style: TextStyle(color: Color(0xFF448AFF))),
            )
          ],
        ),
      );
    });

    socket.connect(); // Conectar explícitamente

    // Llamada entrante al residente
    socket.on('incoming-call', (data) {
      if (!mounted) return;
      if (data is Map && data['caller_rut'] == miRut) return;
      _mostrarLlamadaEntrante(data);
    });

    socket.on('user-status', (data) {
      if (!mounted) return;
      setState(() {
        if (data['ocupado'] == true) {
          rutosOcupados.add(data['rut'].toString());
        } else {
          rutosOcupados.remove(data['rut'].toString());
        }
      });
    });

    socket.on('busy', (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔴 Línea ocupada. El conserje está en otra llamada.'),
          backgroundColor: Color(0xFFff5252),
        ),
      );
    });


    socket.on('chat-message', (data) {
      if (!mounted || data is! Map) return;
      final receptor = (data['rut_receptor'] ?? '').toString();
      final emisor = (data['rut_emisor'] ?? '').toString();
      if (receptor == miRut && emisor != miRut) {
        final sender = (data['sender_label'] ?? emisor).toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Nuevo mensaje de $sender'),
            backgroundColor: const Color(0xFF448AFF),
            action: SnackBarAction(
              label: 'Abrir',
              textColor: Colors.white,
              onPressed: _abrirMensajes,
            ),
          ),
        );
      }
    });

    socket.on('missed-call', (data) {
      if (!mounted) return;
      _detenerTono();
      if (_dialogoEntranteAbierto) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      final caller = data is Map
          ? (data['caller_dpto'] ?? data['caller_rut'] ?? 'Citófono').toString()
          : 'Citófono';
      CallNotifications.showMissedCall(
        caller: caller,
        reason: data is Map ? data['reason']?.toString() : 'ocupado',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('☎️ Llamada perdida de $caller'),
          backgroundColor: const Color(0xFFFF5252),
        ),
      );
    });

    socket.on('end-call', (data) {
      if (!mounted) return;
      _detenerTono();
      if (_dialogoEntranteAbierto) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    });
  }



  void _mostrarLlamadaEntrante(dynamic data) {
    if (!mounted) return;

    final Map<dynamic, dynamic> payload = data is Map ? data : <dynamic, dynamic>{};
    final bool esCitofono = isCitofonoAudioCall(payload);
    Timer? handsetTimer;
    bool handled = false;

    void cancelHandsetTimer() {
      handsetTimer?.cancel();
      handsetTimer = null;
    }

    void aceptarEntrante({required bool desdeBanana}) {
      if (handled || !mounted) return;
      handled = true;
      cancelHandsetTimer();
      _detenerTono();
      Navigator.of(context, rootNavigator: true).pop();

      Navigator.push(context, MaterialPageRoute(
        builder: (_) => esCitofono
            ? CitofonoAudioScreen(
                room: payload['caller_rut']?.toString() ?? '',
                isCaller: false,
                socket: socket,
                miRut: miRut,
                rutDestino: payload['caller_rut']?.toString() ?? '',
                callId: payload['call_id']?.toString(),
                initialSpeakerOn: !desdeBanana,
              )
            : LlamadaScreen(
                room: payload['caller_rut']?.toString() ?? '',
                isCaller: false,
                tipo: payload['tipo']?.toString() ?? 'video',
                socket: socket,
                miRut: miRut,
                rutDestino: payload['caller_rut']?.toString() ?? '',
              ),
      ));
    }

    Future<void> revisarBanana() async {
      if (handled || !mounted) return;
      final state = await Esp32AudioBridge.getHandsetState();
      if (handled || !mounted) return;
      if (state['handsetLifted'] == true) {
        aceptarEntrante(desdeBanana: true);
      }
    }

    _tocarTono();

    if (esCitofono) {
      Esp32AudioBridge.resetHandsetState().then((_) {
        if (handled || !mounted) return;
        handsetTimer = Timer.periodic(
          const Duration(milliseconds: 250),
          (_) => revisarBanana(),
        );
        revisarBanana();
      });
    }

    _dialogoEntranteAbierto = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF222233),
        title: const Text('📞 Llamada entrante', style: TextStyle(color: Colors.white)),
        content: Text(
          'De: ${payload['caller_dpto'] ?? payload['caller_rut']}',
          style: const TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () {
              handled = true;
              cancelHandsetTimer();
              _rechazarEntrante(payload);
            },
            child: const Text('Rechazar', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF448AFF)),
            onPressed: () => aceptarEntrante(desdeBanana: false),
            child: const Text('Aceptar'),
          ),
        ],
      ),
    ).then((_) {
      cancelHandsetTimer();
      _dialogoEntranteAbierto = false;
    });
  }



  Future<void> _rechazarEntrante(dynamic data) async {
    _detenerTono();
    if (mounted) Navigator.pop(context);

    final Map<dynamic, dynamic> payload = data is Map ? data : <dynamic, dynamic>{};
    final bool esCitofono = isCitofonoAudioCall(payload);

    if (!esCitofono) {
      socket.emit('busy', {'room': payload['caller_rut']});
      return;
    }

    final callId = payload['call_id']?.toString();
    try {
      socket.emit('citofono-end-call', {
        'call_id': callId,
        'reason': 'rechazada',
        'estado': 'rechazada',
      });
      await http.post(
        Uri.parse('$kBaseUrl/api/esp32/end-call'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'call_id': callId,
          'room': payload['caller_rut']?.toString(),
          'rut_emisor': payload['caller_rut']?.toString(),
          'rut_receptor': miRut,
          'tipo_llamada': 'audio',
          'estado': 'rechazada',
          'reason': 'rechazada',
          'duracion_segundos': 0,
        }),
      );
    } catch (_) {}
  }

  Future<void> _llamar(String rut, String tipo) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: Color(0xFF222233),
        content: Row(
          children: [
            CircularProgressIndicator(color: Color(0xFF448AFF)),
            SizedBox(width: 20),
            Text('📞 Llamando...', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );

    try {
      final res = await http.post(
        Uri.parse('$kBaseUrl/llamar'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'rut': rut,
          'tipo': tipo,
          'caller_rut': miRut,
          'caller_dpto': 'Depto',
        }),
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      Navigator.pop(context); // Cerrar loading

      final data = jsonDecode(res.body);
      debugPrint('📡 /llamar: ${res.statusCode} - ${res.body}');

      if (data['success'] == true || data['warning'] != null) {
        final bool esCitofono = isCitofonoTarget(rut);
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => esCitofono
              ? CitofonoAudioScreen(
                  room: miRut,
                  isCaller: true,
                  socket: socket,
                  miRut: miRut,
                  rutDestino: rut, // A quien estoy llamando
                  callId: data['call_id']?.toString(),
                )
              : LlamadaScreen(
                  room: miRut,
                  isCaller: true,
                  tipo: tipo,
                  socket: socket,
                  miRut: miRut,
                  rutDestino: rut, // A quien estoy llamando
                ),
        ));
      } else {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: const Color(0xFF222233),
            title: const Text('⚠️ Error', style: TextStyle(color: Colors.orange)),
            content: Text(res.body, style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK', style: TextStyle(color: Color(0xFF448AFF))),
              )
            ],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      debugPrint('❌ Error _llamar residente: $e');
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF222233),
          title: const Text('❌ Sin conexión', style: TextStyle(color: Colors.red)),
          content: Text(e.toString(), style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK', style: TextStyle(color: Color(0xFF448AFF))),
            )
          ],
        ),
      );
    }
  }

  Future<void> _cargarOcupados() async {
    try {
      final res = await http.get(Uri.parse('$kBaseUrl/usuarios-en-llamada'));
      final List lista = jsonDecode(res.body);
      setState(() => rutosOcupados = Set<String>.from(lista));
    } catch (_) {}
  }

  void _abrirDirectorio() async {
    await _cargarOcupados();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DirectorioModal(
        miRut: miRut,
        rutosOcupados: rutosOcupados,
        onLlamar: _llamar,
      ),
    );
  }

  void _abrirMensajes() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MensajesModal(miRut: miRut),
    );
  }

  void _abrirHistorial() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => HistorialModal(miRut: miRut),
    );
  }

  void _cerrarSesion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    socket.disconnect();
    if (!mounted) return;
    Navigator.pushReplacement(context,
        MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  void dispose() {
    socket.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF448AFF).withOpacity(0.3),
                  blurRadius: 80,
                  spreadRadius: 20,
                ),
              ],
            ),
          ),
          const Positioned(
            top: 50,
            left: 20,
            child: Text('Inicio', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w300, color: Colors.white)),
          ),
          Positioned(
            top: 40,
            right: 15,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: _socketConectado ? Colors.green : Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _socketConectado ? 'Conectado' : 'Desconectado',
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  icon: const Icon(Icons.logout, color: Colors.grey),
                  onPressed: _cerrarSesion,
                ),
              ],
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Bienvenido a la app', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w300, color: Colors.white)),
                const SizedBox(height: 10),
                Text('RUT: $miRut', style: const TextStyle(color: Colors.grey, fontSize: 16)),
                if (miDpto.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text('Depto/Casa: $miDpto', style: const TextStyle(color: Colors.grey, fontSize: 16)),
                ],
                const SizedBox(height: 5),
                const Text('Rol: Residente', style: TextStyle(color: Color(0xFF4CAF50), fontSize: 16)),
              ],
            ),
          ),
          Positioned(
            bottom: 30,
            left: 30,
            child: FloatingActionButton(
              heroTag: 'fab_historial',
              backgroundColor: const Color(0xFF333344),
              onPressed: _abrirHistorial,
              child: const Icon(Icons.history_rounded, color: Colors.white),
            ),
          ),
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton.extended(
                heroTag: 'fab_mensajes',
                backgroundColor: const Color(0xFF4CAF50),
                onPressed: _abrirMensajes,
                icon: const Icon(Icons.chat_bubble_rounded, color: Colors.white),
                label: const Text('Mensajes', style: TextStyle(color: Colors.white)),
              ),
            ),
          ),
          Positioned(
            bottom: 30,
            right: 30,
            child: FloatingActionButton(
              heroTag: 'fab_directorio',
              backgroundColor: const Color(0xFF448AFF),
              onPressed: _abrirDirectorio,
              child: const Icon(Icons.grid_view_rounded, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
