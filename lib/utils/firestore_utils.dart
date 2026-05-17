/// Safely converts a Firestore field that should be an Array but may have
/// been corrupted to a Map<String,dynamic> (numeric keys "0","1",...) by a
/// dot-notation update (e.g. buses.0.passengers.1.x = true).
List<dynamic> asList(dynamic value) {
  if (value == null) return const [];
  if (value is List) return value;
  if (value is Map) {
    final keys = value.keys.toList()
      ..sort((a, b) {
        final ia = int.tryParse(a.toString());
        final ib = int.tryParse(b.toString());
        if (ia != null && ib != null) return ia.compareTo(ib);
        return a.toString().compareTo(b.toString());
      });
    return keys.map((k) => value[k]).toList();
  }
  return const [];
}
