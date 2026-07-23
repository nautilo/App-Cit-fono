import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'screens/login_screen.dart';
import 'screens/llamada_screen.dart';
import 'screens/citofono_audio_screen.dart';
import 'helpers/citofono_call_utils.dart';
import 'helpers/call_notifications.dart';
import 'helpers/message_navigation.dart';
import 'widgets/mensajes_modal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:ui';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
Future<void> openMessagesFromNotification({String? peerRut}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kOpenMessagesPendingKey, true);

  final rut = prefs.getString('rut') ?? '';
  final context = navigatorKey.currentContext;
  if (rut.isEmpty || context == null) return;

  await prefs.setBool(kOpenMessagesPendingKey, false);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MensajesModal(miRut: rut),
    );
  });
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

// ─── HANDLER DE SEGUNDO PLANO ──────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await Firebase.initializeApp();

  final type = message.data['type'];

  if (type == 'call') {
    final callerRut = message.data['caller_rut'];
    final prefs = await SharedPreferences.getInstance();
    final miRut = prefs.getString('rut') ?? '';
    if (callerRut == miRut && miRut.isNotEmpty) return;

    final caller = message.data['caller_dpto'] ?? message.data['caller_rut'] ?? 'Conserjería';

    try {
      FlutterRingtonePlayer().playRingtone();
    } catch (_) {}

    await CallNotifications.showIncomingCall(caller: caller);
    return;
  }

  if (type == 'missed_call') {
    final caller = message.data['caller_dpto'] ?? message.data['caller_rut'] ?? 'Citófono';
    await CallNotifications.showMissedCall(
      caller: caller,
      reason: message.data['reason']?.toString(),
    );
    return;
  }

  if (type == 'chat_message') {
    final sender = message.data['sender_label'] ?? message.data['rut_emisor'] ?? 'Depto/Casa';
    final body = message.data['mensaje'] ?? 'Nuevo mensaje';
    final peerRut = message.data['rut_emisor']?.toString();
    await CallNotifications.showChatMessage(
      sender: sender.toString(),
      body: body.toString(),
      peerRut: peerRut,
    );
  }
}


void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    HttpOverrides.global = MyHttpOverrides();
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    await CallNotifications.ensureInitialized(
      onResponse: (response) {
        final payload = response.payload ?? '';
        if (payload.startsWith('chat_message')) {
          openMessagesFromNotification();
          return;
        }
        FlutterRingtonePlayer().stop();
        CallNotifications.cancelIncoming();
      },
    );
    runApp(const CitofonoApp());

  } catch (error, stackTrace) {
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.red,
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                "ERROR DE INICIO FATAL:\n\n$error\n\n$stackTrace",
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CitofonoApp extends StatefulWidget {
  const CitofonoApp({super.key});

  @override
  State<CitofonoApp> createState() => _CitofonoAppState();
}

class _CitofonoAppState extends State<CitofonoApp> {
  @override
  void initState() {
    super.initState();
    _setupInteractions();
  }

  void _setupInteractions() async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      debugPrint('🔔 Mensaje recibido en primer plano');
      
      final prefs = await SharedPreferences.getInstance();
      final miRut = prefs.getString('rut') ?? '';
      if (message.data['caller_rut'] == miRut && miRut.isNotEmpty) return;

      if (message.data['type'] == 'call') {
        FlutterRingtonePlayer().playRingtone();
      } else if (message.data['type'] == 'missed_call') {
        FlutterRingtonePlayer().stop();
        final caller = message.data['caller_dpto'] ?? message.data['caller_rut'] ?? 'Citófono';
        CallNotifications.showMissedCall(
          caller: caller,
          reason: message.data['reason']?.toString(),
        );
      } else if (message.data['type'] == 'chat_message') {
        final sender = message.data['sender_label'] ?? message.data['rut_emisor'] ?? 'Depto/Casa';
        final body = message.data['mensaje'] ?? 'Nuevo mensaje';
        final peerRut = message.data['rut_emisor']?.toString();
        CallNotifications.showChatMessage(
          sender: sender.toString(),
          body: body.toString(),
          peerRut: peerRut,
        );
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('📩 Notificación clickeada (app en background)');
      _detenerTodoYEntrar(message);
    });

    FirebaseMessaging.instance.getInitialMessage().then((message) {
      if (message != null) {
        debugPrint('🚀 App abierta desde notificación muerta');
        _detenerTodoYEntrar(message);
      }
    });
  }

  void _detenerTodoYEntrar(RemoteMessage message) {
    if (message.data['type'] == 'chat_message') {
      openMessagesFromNotification(peerRut: message.data['rut_emisor']?.toString());
      return;
    }
    FlutterRingtonePlayer().stop();
    CallNotifications.cancelIncoming();
    _handlePushCall(message);
  }

  void _handlePushCall(RemoteMessage message) async {
    if (message.data['type'] != 'call') {
      return;
    }

    if (message.data['type'] == 'call') {
      final String callerRut = message.data['caller_rut'] ?? 'desconocido';
      final String tipo = message.data['tipo'] ?? 'video';

      final prefs = await SharedPreferences.getInstance();
      final String miRut = prefs.getString('rut') ?? '';

      if (miRut.isEmpty) return;

      final bool esCitofono = isCitofonoAudioCall(message.data);

      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => esCitofono
              ? CitofonoAudioScreen(
                  room: callerRut,
                  isCaller: false,
                  socket: null,
                  miRut: miRut,
                  rutDestino: callerRut,
                  callId: message.data['call_id'],
                )
              : LlamadaScreen(
                  room: callerRut,
                  isCaller: false,
                  tipo: tipo,
                  socket: null,
                  miRut: miRut,
                  rutDestino: callerRut,
                ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Citófono',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF448AFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF11111B),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}
