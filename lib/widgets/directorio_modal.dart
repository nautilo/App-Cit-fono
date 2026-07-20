import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config.dart';

class DirectorioModal extends StatefulWidget {
  final String miRut;
  final Set<String> rutosOcupados;
  final Function(String rut, String tipo) onLlamar;
  // --- NUEVO: Recibe el mapa con los mensajes sin leer por remitente ---
  final Map<String, int> mensajesSinLeerPorUsuario;

  const DirectorioModal({
    super.key,
    required this.miRut,
    required this.rutosOcupados,
    required this.onLlamar,
    this.mensajesSinLeerPorUsuario = const {}, // Por defecto vacío por si acaso
  });

  @override
  State<DirectorioModal> createState() => _DirectorioModalState();
}

class _DirectorioModalState extends State<DirectorioModal> {
  List<dynamic> _usuarios = [];
  List<dynamic> _filtrados = [];
  final _searchCtrl = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _cargarUsuarios();
  }

  Future<void> _cargarUsuarios() async {
    try {
      final res = await http.get(Uri.parse('$kBaseUrl/usuarios-todos?rut=${widget.miRut}'));
      final List data = jsonDecode(res.body);
      final List<dynamic> contactos = [
        {
          'rut_usuario': 'CITOFONO',
          'nombres': 'Citófono',
          'apellido_1': 'principal',
          'id_dpto': 'Acceso',
          'es_citofono': true,
        },
        ...data,
      ];
      setState(() {
        _usuarios = contactos;
        _filtrados = contactos;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _filtrar(String query) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) {
      setState(() => _filtrados = _usuarios);
      return;
    }
    setState(() {
      _filtrados = _usuarios.where((u) {
        final dpto = (u['id_dpto'] ?? '').toString();
        final superString = [
          u['nombres'] ?? '',
          u['apellido_1'] ?? '',
          u['rut_usuario'] ?? '',
          'depto', 'departamento', dpto,
          'depto $dpto', 'departamento $dpto',
          u['es_citofono'] == true ? 'citofono citófono porteria portería acceso' : '',
        ].join(' ').toLowerCase();
        return superString.contains(q);
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF11111B),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey[700], borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Directorio de Contactos',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w300)),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: _filtrar,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Buscar por nombre, RUT o Depto...',
                  hintStyle: const TextStyle(color: Colors.grey),
                  prefixIcon: const Icon(Icons.search, color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF222233),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF444444)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF444444)),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF448AFF)))
                  : ListView.builder(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _filtrados.length,
                      itemBuilder: (_, i) {
                        final u = _filtrados[i];
                        final rut = (u['rut_usuario'] ?? '').toString();
                        final ocupado = widget.rutosOcupados.contains(rut);
                        
                        // --- NUEVO: Obtener la cantidad de mensajes sin leer de este usuario específico ---
                        final unreadCount = widget.mensajesSinLeerPorUsuario[rut] ?? 0;

                        return _UserCard(
                          usuario: u,
                          ocupado: ocupado,
                          unreadCount: unreadCount, // <-- Enviado a la tarjeta
                          onLlamar: (tipo) async {
                            Navigator.pop(context);
                            await Future.delayed(const Duration(milliseconds: 300));
                            widget.onLlamar(rut, tipo);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  final Map usuario;
  final bool ocupado;
  final int unreadCount; // --- NUEVO ---
  final Function(String tipo) onLlamar;

  const _UserCard({
    required this.usuario,
    required this.ocupado,
    required this.unreadCount, // --- NUEVO ---
    required this.onLlamar,
  });

  @override
  Widget build(BuildContext context) {
    final bool esCitofono = usuario['es_citofono'] == true || usuario['rut_usuario'] == 'CITOFONO';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF222233),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF333344)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Usamos Flexible para que nombres muy largos no rompan el diseño con los badges
              Flexible(
                child: Text(
                  '${usuario['nombres'] ?? ''} ${usuario['apellido_1'] ?? ''}',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              
              // --- NUEVO: Badge indicador de mensajes no leídos enviados por este usuario ---
              if (unreadCount > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF9800), // Color naranjo/advertencia llamativo
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.mail_rounded, color: Colors.white, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        '$unreadCount',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ],

              if (ocupado) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFff5252),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('🔴 Ocupado', style: TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Depto/Casa: ${usuario['id_dpto'] ?? 'N/A'} | RUT: ${usuario['rut_usuario']}',
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!esCitofono) ...[
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: ocupado ? null : () => onLlamar('video'),
                    icon: const Icon(Icons.videocam_rounded, size: 18),
                    label: const Text('Videollamar'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ocupado ? Colors.grey[800] : const Color(0xFF448AFF),
                      foregroundColor: Colors.white,
                      shape: const StadiumBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: ocupado ? null : () => onLlamar('audio'),
                  icon: Icon(esCitofono ? Icons.doorbell_rounded : Icons.call_rounded, size: 18),
                  label: Text(esCitofono ? 'Llamar al citófono' : 'Llamar'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ocupado ? Colors.grey[800] : const Color(0xFF4CAF50),
                    foregroundColor: Colors.white,
                    shape: const StadiumBorder(),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}