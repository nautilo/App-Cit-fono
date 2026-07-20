import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../config.dart';
import 'conserje_screen.dart';
import 'residente_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _rutController = TextEditingController();
  final _claveController = TextEditingController();
  bool _loading = false;

  Future<void> _login() async {
    final rut = _rutController.text.trim();
    final clave = _claveController.text.trim();
    if (rut.isEmpty || clave.isEmpty) return;

    setState(() => _loading = true);

    try {
      final res = await http.post(
        Uri.parse('$kBaseUrl/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'rut': rut, 'password': clave}),
      );

      final data = jsonDecode(res.body);
      if (data['success'] == true) {
        final prefs = await SharedPreferences.getInstance();

        // Opcional: Solicitar token FCM y registrarlo en backend
        try {
          final token = await FirebaseMessaging.instance.getToken();
          if (token != null) {
            await http.post(
              Uri.parse('$kBaseUrl/registrar-token'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'rut': (data['rut'] ?? rut).toString(), 'token': token}),
            );
            debugPrint('✅ Token FCM registrado para $rut');
          }
        } catch (e) {
          debugPrint('⚠️ No se pudo registrar el token FCM: $e');
        }

        // Forzar conversión a String para evitar errores de tipo
        final rutString = (data['rut'] ?? '').toString();
        final nombre = (data['nombre'] ?? '').toString();
        final dpto = (data['dpto'] ?? '').toString();

        // es_admin puede venir como int (1/0) o bool (true/false)
        final esAdminRaw = data['es_admin'];
        final esAdmin = (esAdminRaw == true || esAdminRaw == 1) ? 1 : 0;

        await prefs.setString('rut', rutString);
        await prefs.setString('nombre', nombre);
        await prefs.setString('dpto', dpto);
        await prefs.setInt('es_admin', esAdmin);

        if (!mounted) return;
        if (esAdmin == 1) {
          Navigator.pushReplacement(context,
              MaterialPageRoute(builder: (_) => const ConserjeScreen()));
        } else {
          Navigator.pushReplacement(context,
              MaterialPageRoute(builder: (_) => const ResidenteScreen()));
        }
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Credenciales inválidas')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error de conexión: $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Resplandor azul en bordes
          Container(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF448AFF).withOpacity(0.35),
                  blurRadius: 80,
                  spreadRadius: 20,
                ),
              ],
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Iniciar sesión',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w300,
                      color: Colors.white,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 35),
                  // Campo RUT
                  TextField(
                    controller: _rutController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'RUT',
                      labelStyle: const TextStyle(color: Colors.grey),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: const BorderSide(color: Color(0xFF444444)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: const BorderSide(color: Color(0xFF448AFF)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 25),
                  // Campo Clave
                  TextField(
                    controller: _claveController,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Clave',
                      labelStyle: const TextStyle(color: Colors.grey),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: const BorderSide(color: Color(0xFF444444)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: const BorderSide(color: Color(0xFF448AFF)),
                      ),
                    ),
                    onSubmitted: (_) => _login(),
                  ),
                  const SizedBox(height: 35),
                  Center(
                    child: _loading
                        ? const CircularProgressIndicator(color: Color(0xFF448AFF))
                        : ElevatedButton.icon(
                            onPressed: _login,
                            icon: const Icon(Icons.login_rounded),
                            label: const Text('Ingresar'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF448AFF),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 35, vertical: 14),
                              shape: const StadiumBorder(),
                              textStyle: const TextStyle(fontSize: 16),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
