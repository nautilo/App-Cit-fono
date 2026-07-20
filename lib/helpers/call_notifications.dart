import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin callNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel callsChannel = AndroidNotificationChannel(
  'calls_channel_v5',
  'Llamadas Citófono',
  description: 'Canal prioritario con tono de llamada',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
);

const AndroidNotificationChannel missedCallsChannel = AndroidNotificationChannel(
  'missed_calls_channel',
  'Llamadas perdidas',
  description: 'Avisos de llamadas no contestadas u ocupadas',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

const AndroidNotificationChannel messagesChannel = AndroidNotificationChannel(
  'messages_channel',
  'Mensajes',
  description: 'Notificaciones de mensajes entre Depto/Casa y conserjería',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

class CallNotifications {
  static bool _initialized = false;

  static Future<void> ensureInitialized({
    DidReceiveNotificationResponseCallback? onResponse,
  }) async {
    if (!_initialized) {
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidSettings);
      await callNotificationsPlugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: onResponse,
      );
      _initialized = true;
    }

    final android = callNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    await android?.createNotificationChannel(callsChannel);
    await android?.createNotificationChannel(missedCallsChannel);
    await android?.createNotificationChannel(messagesChannel);
  }

  static Future<void> showIncomingCall({
    required String caller,
    int id = 999,
  }) async {
    await ensureInitialized();
    await callNotificationsPlugin.show(
      id,
      '📞 Llamada entrante',
      'De: $caller',
      NotificationDetails(
        android: AndroidNotificationDetails(
          callsChannel.id,
          callsChannel.name,
          channelDescription: callsChannel.description,
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.call,
          visibility: NotificationVisibility.public,
          ongoing: true,
          autoCancel: false,
          color: const Color(0xFF448AFF),
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
  }

  static Future<void> showMissedCall({
    required String caller,
    String? reason,
    int? id,
  }) async {
    await ensureInitialized();
    final notificationId = id ?? (2000 + DateTime.now().millisecondsSinceEpoch.remainder(700000));
    final detail = (reason == null || reason.isEmpty || reason == 'ocupado')
        ? 'No fue contestada porque la línea estaba ocupada.'
        : reason;

    await callNotificationsPlugin.show(
      notificationId,
      '☎️ Llamada perdida',
      '$caller · $detail',
      NotificationDetails(
        android: AndroidNotificationDetails(
          missedCallsChannel.id,
          missedCallsChannel.name,
          channelDescription: missedCallsChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.status,
          visibility: NotificationVisibility.public,
          autoCancel: true,
          color: const Color(0xFFFF5252),
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
  }

  static Future<void> showChatMessage({
    required String sender,
    required String body,
    String? peerRut,
    int? id,
  }) async {
    await ensureInitialized();
    final notificationId = id ?? (3000 + DateTime.now().millisecondsSinceEpoch.remainder(700000));
    final cleanBody = body.trim().isEmpty ? 'Nuevo mensaje' : body.trim();

    await callNotificationsPlugin.show(
      notificationId,
      'Nuevo mensaje de $sender',
      cleanBody,
      NotificationDetails(
        android: AndroidNotificationDetails(
          messagesChannel.id,
          messagesChannel.name,
          channelDescription: messagesChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
          autoCancel: true,
          color: const Color(0xFF448AFF),
          icon: '@mipmap/ic_launcher',
        ),
      ),
      payload: peerRut == null || peerRut.isEmpty ? 'chat_message' : 'chat_message:$peerRut',
    );
  }

  static Future<void> cancelIncoming() async {
    await callNotificationsPlugin.cancel(999);
  }
}
