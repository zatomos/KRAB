import 'package:flutter_test/flutter_test.dart';
import 'package:krab/services/cache/bounded_cache.dart';

void main() {
  group('BoundedCache', () {
    test('reads back what was written', () {
      final cache = BoundedCache<int>(3)..['a'] = 1;
      expect(cache['a'], 1);
      expect(cache['missing'], isNull);
    });

    test('drops the oldest entry once over the bound', () {
      final cache = BoundedCache<int>(2);
      cache['a'] = 1;
      cache['b'] = 2;
      cache['c'] = 3;

      expect(cache['a'], isNull, reason: 'the oldest should have been evicted');
      expect(cache['b'], 2);
      expect(cache['c'], 3);
    });

    test('re-writing a key makes it the newest, not the oldest', () {
      final cache = BoundedCache<int>(2);
      cache['a'] = 1;
      cache['b'] = 2;
      cache['a'] = 10; // 'a' is now the most recently stored
      cache['c'] = 3;

      expect(cache['b'], isNull, reason: 'b is now the oldest');
      expect(cache['a'], 10);
      expect(cache['c'], 3);
    });

    test('never grows past the bound', () {
      final cache = BoundedCache<int>(5);
      for (var i = 0; i < 100; i++) {
        cache['key$i'] = i;
      }
      // The last 5 survive, everything before them is gone.
      expect(cache['key94'], isNull);
      for (var i = 95; i < 100; i++) {
        expect(cache['key$i'], i);
      }
    });

    test('remove and clear forget entries', () {
      final cache = BoundedCache<int>(3);
      cache['a'] = 1;
      cache['b'] = 2;

      cache.remove('a');
      expect(cache['a'], isNull);
      expect(cache['b'], 2);

      cache.clear();
      expect(cache['b'], isNull);
    });
  });
}
