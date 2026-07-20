import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config.dart';

class HistorialModal extends StatefulWidget {
  final String miRut;
  const HistorialModal({super.key, required this.miRut});

  @override
  State<HistorialModal> createState() => _HistorialModalState();
}

class _HistorialModalState extends State<HistorialModal> {
  List<dynamic> _historial = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final res = await http.get(
        Uri.parse('$kBaseUrl/historial?rut=${widget.miRut}'),
      );
      final List data = jsonDecode(res.body);
      setState(() {
        _historial = data;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Color _colorEstado(String estado) {
    switch (estado) {
      case 'finalizada': return const Color(0xFF4CAF50);
      case 'ocupado': return const Color(0xFFffb142);
      case 'perdida': return const Color(0xFFff5252);
      default: return Colors.grey;
    }
  }

  IconData _iconEstado(String estado) {
    switch (estado) {
      case 'finalizada': return Icons.call_made_rounded;
      case 'ocupado': return Icons.phone_missed_rounded;
      case 'perdida': return Icons.phone_missed_rounded;
      default: return Icons.call_rounded;
    }
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
                  const Text('Historial de Llamadas',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w300)),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF448AFF)))
                  : _historial.isEmpty
                      ? const Center(child: Text('No hay historial de llamadas.', style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          controller: scrollCtrl,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: _historial.length,
                          itemBuilder: (_, i) {
                            final l = _historial[i];
                            final esEmisor = l['rut_emisor'] == widget.miRut;
                            final otroRut = esEmisor ? l['rut_receptor'] : l['rut_emisor'];
                            final direccion = esEmisor ? 'Saliente a' : 'Entrante de';
                            final estado = l['estado'] ?? 'finalizada';
                            final fecha = l['fecha_hora'] != null
                                ? DateTime.tryParse(l['fecha_hora'])?.toLocal()
                                : null;
                            return Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(15),
                              decoration: BoxDecoration(
                                color: const Color(0xFF222233),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFF333344)),
                              ),
                              child: Row(
                                children: [
                                  Icon(_iconEstado(estado), color: _colorEstado(estado), size: 28),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '$direccion $otroRut',
                                          style: TextStyle(color: _colorEstado(estado), fontSize: 15),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          fecha != null
                                              ? '${fecha.day}/${fecha.month}/${fecha.year} ${fecha.hour}:${fecha.minute.toString().padLeft(2, '0')}'
                                              : '',
                                          style: const TextStyle(color: Colors.grey, fontSize: 12),
                                        ),
                                        Text(
                                          'Tipo: ${l['tipo_llamada']} | Estado: $estado | ${l['duracion_segundos']}s',
                                          style: const TextStyle(color: Colors.grey, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
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
