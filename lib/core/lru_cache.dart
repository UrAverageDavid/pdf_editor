import 'dart:collection';

class LruCache<K, V> {
  LruCache({required this.budgetBytes, required this.sizeOf, required this.onEvict});
  final int budgetBytes;
  final int Function(V) sizeOf;
  final void Function(V) onEvict;
  final _items = LinkedHashMap<K, V>();
  int _bytes = 0;
  int get usedBytes => _bytes;
  int get length => _items.length;

  V? get(K key) {
    final value = _items.remove(key);
    if (value != null) _items[key] = value;
    return value;
  }

  void put(K key, V value) {
    final old = _items.remove(key);
    if (old != null) { _bytes -= sizeOf(old); onEvict(old); }
    _items[key] = value;
    _bytes += sizeOf(value);
    while (_bytes > budgetBytes && _items.isNotEmpty) {
      final removed = _items.remove(_items.keys.first) as V;
      _bytes -= sizeOf(removed);
      onEvict(removed);
    }
  }

  void clear() {
    for (final value in _items.values) { onEvict(value); }
    _items.clear();
    _bytes = 0;
  }
}
