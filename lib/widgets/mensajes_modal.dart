import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../config.dart';

class MensajesModal extends StatefulWidget {
  final String miRut;

  const MensajesModal({super.key, required this.miRut});

  @override
  State<MensajesModal> createState() => _MensajesModalState();
}

class _MensajesModalState extends State<MensajesModal> {
  final TextEditingController _mensajeController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _pollTimer;

  bool _loadingContactos = true;
  bool _loadingMensajes = false;
  String? _error;
  String _unidadPropia = 'Depto/Casa';
  Map<String, dynamic>? _contactoSeleccionado;
  List<Map<String, dynamic>> _contactos = [];
  List<Map<String, dynamic>> _mensajes = [];

  @override
  void initState() {
    super.initState();
    _cargarContactos();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_contactoSeleccionado != null) {
        _cargarMensajes(silencioso: true);
      } else {
        _cargarContactos(silencioso: true);
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _mensajeController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _contactoRut(Map<String, dynamic> c) => (c['rut_usuario'] ?? '').toString();

  String _contactoTitulo(Map<String, dynamic> c) {
    final display = (c['display_name'] ?? '').toString().trim();
    if (display.isNotEmpty) return display;

    final esAdmin = c['es_admin'] == true || c['es_admin'] == 1;
    final nombre = '${c['nombres'] ?? ''} ${c['apellido_1'] ?? ''}'.trim();
    if (esAdmin) return nombre.isEmpty ? 'Conserjería' : nombre;

    final unidad = (c['id_dpto'] ?? '').toString().trim();
    final label = unidad.isEmpty ? 'Depto/Casa' : 'Depto/Casa $unidad';
    return nombre.isEmpty ? label : '$label - $nombre';
  }

  Future<void> _cargarContactos({bool silencioso = false}) async {
    if (!silencioso) {
      setState(() {
        _loadingContactos = true;
        _error = null;
      });
    }

    try {
      final uri = Uri.parse('$kBaseUrl/api/chat/contactos').replace(
        queryParameters: {'rut': widget.miRut},
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      if (res.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? res.body);
      }

      final contactos = (data['contactos'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      if (!mounted) return;
      setState(() {
        _contactos = contactos;
        _unidadPropia = (data['unidad_label'] ?? 'Depto/Casa').toString();
        _loadingContactos = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silencioso) {
        setState(() {
          _loadingContactos = false;
          _error = 'No se pudieron cargar contactos: $e';
        });
      }
    }
  }

  Future<void> _cargarMensajes({bool silencioso = false}) async {
    final contacto = _contactoSeleccionado;
    if (contacto == null) return;

    if (!silencioso) {
      setState(() {
        _loadingMensajes = true;
        _error = null;
      });
    }

    try {
      final uri = Uri.parse('$kBaseUrl/api/chat/messages').replace(
        queryParameters: {
          'rut': widget.miRut,
          'peer': _contactoRut(contacto),
          'limit': '50',
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      if (res.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? res.body);
      }

      final mensajes = (data['messages'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      if (!mounted) return;
      setState(() {
        _mensajes = mensajes;
        _loadingMensajes = false;
        _error = null;
      });
      _bajarAlFinal();
    } catch (e) {
      if (!mounted) return;
      if (!silencioso) {
        setState(() {
          _loadingMensajes = false;
          _error = 'No se pudieron cargar mensajes: $e';
        });
      }
    }
  }

  Future<void> _enviarMensaje() async {
    final contacto = _contactoSeleccionado;
    final texto = _mensajeController.text.trim();
    if (contacto == null || texto.isEmpty) return;

    _mensajeController.clear();
    try {
      final res = await http.post(
        Uri.parse('$kBaseUrl/api/chat/messages'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'rut_emisor': widget.miRut,
          'rut_receptor': _contactoRut(contacto),
          'mensaje': texto,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? res.body);
      }
      await _cargarMensajes(silencioso: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo enviar: $e')),
      );
    }
  }

  void _mostrarOpcionesImagen() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF222233),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded, color: Colors.white),
              title: const Text('Tomar Foto', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _seleccionarYSubir(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded, color: Colors.white),
              title: const Text('Elegir de Galería', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _seleccionarYSubir(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _seleccionarYSubir(ImageSource source) async {
    try {
      final XFile? pickedFile = await ImagePicker().pickImage(source: source, imageQuality: 70);
      if (pickedFile == null) {
        print('No se seleccionó ninguna imagen.');
        return;
      }
      
      final contacto = _contactoSeleccionado;
      if (contacto == null) return;

      setState(() {
        _loadingMensajes = true;
      });

      print('Preparando subida de imagen: ${pickedFile.path}');
      var request = http.MultipartRequest('POST', Uri.parse('$kBaseUrl/api/chat/upload'));
      request.fields['rut_emisor'] = widget.miRut;
      request.fields['rut_receptor'] = _contactoRut(contacto);
      request.files.add(await http.MultipartFile.fromPath('file', pickedFile.path));

      print('Enviando a $kBaseUrl/api/chat/upload ...');
      final streamedResponse = await request.send().timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamedResponse);
      print('Status Code de Subida: ${response.statusCode}');
      print('Respuesta del servidor: ${response.body}');
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? response.body);
      }
      print('Subida exitosa, recargando mensajes...');
      await _cargarMensajes(silencioso: true);
    } catch (e) {
      print('Error grave al subir imagen: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo enviar la imagen: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _loadingMensajes = false;
        });
      }
    }
  }

  void _bajarAlFinal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _seleccionarContacto(Map<String, dynamic> contacto) {
    setState(() {
      _contactoSeleccionado = contacto;
      _mensajes = [];
    });
    _cargarMensajes();
  }

  Widget _buildHeader() {
    final contacto = _contactoSeleccionado;
    return Row(
      children: [
        IconButton(
          icon: Icon(contacto == null ? Icons.close_rounded : Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () {
            if (contacto == null) {
              Navigator.pop(context);
            } else {
              setState(() => _contactoSeleccionado = null);
              _cargarContactos();
            }
          },
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                contacto == null ? 'Mensajes' : _contactoTitulo(contacto),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
              ),
              Text(
                contacto == null ? 'Cuenta compartida: $_unidadPropia + pantalla puerta' : 'Chat por Depto/Casa',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.refresh_rounded, color: Color(0xFF448AFF)),
          onPressed: contacto == null ? _cargarContactos : _cargarMensajes,
        ),
      ],
    );
  }

  Widget _buildContactos() {
    if (_loadingContactos) {
      return const Expanded(child: Center(child: CircularProgressIndicator(color: Color(0xFF448AFF))));
    }
    if (_contactos.isEmpty) {
      return const Expanded(child: Center(child: Text('No hay contactos disponibles.', style: TextStyle(color: Colors.grey))));
    }

    return Expanded(
      child: ListView.builder(
        itemCount: _contactos.length,
        itemBuilder: (context, index) {
          final c = _contactos[index];
          final unread = int.tryParse((c['unread'] ?? '0').toString()) ?? 0;
          final esAdmin = c['es_admin'] == true || c['es_admin'] == 1;
          return Card(
            color: const Color(0xFF222233),
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: esAdmin ? const Color(0xFF448AFF) : const Color(0xFF4CAF50),
                child: Icon(esAdmin ? Icons.support_agent_rounded : Icons.home_rounded, color: Colors.white),
              ),
              title: Text(_contactoTitulo(c), style: const TextStyle(color: Colors.white)),
              subtitle: Text('RUT: ${_contactoRut(c)}', style: const TextStyle(color: Colors.white54)),
              trailing: unread > 0
                  ? CircleAvatar(
                      radius: 13,
                      backgroundColor: const Color(0xFFFF5252),
                      child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 12)),
                    )
                  : const Icon(Icons.chevron_right_rounded, color: Colors.white38),
              onTap: () => _seleccionarContacto(c),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMensajes() {
    final contacto = _contactoSeleccionado;
    if (contacto == null) return const SizedBox.shrink();

    return Expanded(
      child: Column(
        children: [
          Expanded(
            child: _loadingMensajes
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF448AFF)))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _mensajes.length,
                    itemBuilder: (context, index) {
                      final m = _mensajes[index];
                      final propio = (m['rut_emisor'] ?? '').toString() == widget.miRut;
                      return Align(
                        alignment: propio ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                          decoration: BoxDecoration(
                            color: propio ? const Color(0xFF448AFF) : const Color(0xFF333344),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: m['es_imagen'] == true
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    '$kBaseUrl${m['mensaje']}',
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, color: Colors.white54),
                                  ),
                                )
                              : Text((m['mensaje'] ?? '').toString(), style: const TextStyle(color: Colors.white, fontSize: 15)),
                        ),
                      );
                    },
                  ),
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.attach_file_rounded, color: Colors.white54),
                onPressed: _mostrarOpcionesImagen,
              ),
              Expanded(
                child: TextField(
                  controller: _mensajeController,
                  minLines: 1,
                  maxLines: 4,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Escribe un mensaje...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: const Color(0xFF222233),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _enviarMensaje(),
                ),
              ),
              const SizedBox(width: 8),
              FloatingActionButton.small(
                heroTag: 'fab_enviar_mensaje_${_contactoRut(contacto)}',
                backgroundColor: const Color(0xFF4CAF50),
                onPressed: _enviarMensaje,
                child: const Icon(Icons.send_rounded, color: Colors.white),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.9,
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 12,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF11111B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(width: 42, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(8))),
          const SizedBox(height: 8),
          _buildHeader(),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.orange)),
          ],
          const SizedBox(height: 8),
          _contactoSeleccionado == null ? _buildContactos() : _buildMensajes(),
        ],
      ),
    );
  }
}
