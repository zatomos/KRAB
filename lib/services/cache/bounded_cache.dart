/// A map that forgets its oldest entry once it grows past maxEntries.
class BoundedCache<V> {
  BoundedCache(this.maxEntries);

  final int maxEntries;
  final Map<String, V> _entries = {};

  V? operator [](String key) => _entries[key];

  void operator []=(String key, V value) {
    _entries
      ..remove(key)
      ..[key] = value;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void remove(String key) => _entries.remove(key);

  void clear() => _entries.clear();
}
