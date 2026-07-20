String _norm(dynamic value) {
  return (value ?? '')
      .toString()
      .trim()
      .toUpperCase()
      .replaceAll('Ó', 'O');
}

bool isCitofonoValue(dynamic value) {
  final v = _norm(value);
  return v == 'CITOFONO' || v == 'CITÓFONO' || v == '99999999' || v.contains('CITOFONO');
}

bool isCitofonoAudioCall(Map<dynamic, dynamic> data) {
  return isCitofonoValue(data['caller_rut']) ||
      isCitofonoValue(data['caller_dpto']) ||
      isCitofonoValue(data['rut']) ||
      isCitofonoValue(data['rut_destino']) ||
      isCitofonoValue(data['target_rut']);
}

bool isCitofonoTarget(String rut) => isCitofonoValue(rut);
