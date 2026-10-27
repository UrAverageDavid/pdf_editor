import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/core/lru_cache.dart';
import 'package:papertrail/features/pdf_viewer/render_service.dart';
import 'document_view_test.dart' show FakePdf;

void main() {
  test('LRU evicts least-recently accessed entries and releases resources', () {
    final evicted = <int>[];
    final cache = LruCache<String, int>(budgetBytes: 8,
      sizeOf: (_) => 4, onEvict: evicted.add);
    cache.put('a', 1);
    cache.put('b', 2);
    expect(cache.get('a'), 1);
    cache.put('c', 3);
    expect(cache.get('b'), isNull);
    expect(cache.usedBytes, 8);
    expect(evicted, [2]);
    cache.clear();
    expect(cache.usedBytes, 0);
    expect(evicted, [2, 1, 3]);
  });

  test('oversized render cannot exceed the cache budget', () {
    final evicted = <int>[];
    final cache = LruCache<String, int>(budgetBytes: 8, sizeOf: (v) => v, onEvict: evicted.add);
    cache.put('large', 32);
    expect(cache.usedBytes, 0);
    expect(evicted, [32]);
  });

  test('PDF tiles retain requested resolution, reuse cache, and cancel queued work', () async {
    final pdf = FakePdf();
    final renders = RenderService(pdf);
    addTearDown(renders.close);
    renders.inkActive = true;
    final cancelled = renders.requestTile(0, 8, const Rect.fromLTWH(0, 0, .1, .1));
    cancelled.cancel();
    const region = Rect.fromLTWH(.2, .3, .1, .1);
    final ticket = renders.requestTile(0, 8, region);
    renders.inkActive = false;
    final image = (await ticket.result)!;
    expect(await cancelled.result, isNull);
    expect(pdf.tiles, [(page: 0, scale: 8.0, region: region)]);
    expect(pdf.rendered, isEmpty);
    final cached = (await renders.requestTile(0, 8, region).result)!;
    expect(pdf.tiles, hasLength(1));
    expect(() => renders.requestTile(0, 8, const Rect.fromLTWH(0, 0, 1, 1)),
      throwsArgumentError);
    image.dispose();
    cached.dispose();
  });

  test('render keys distinguish page, scale, and tile', () {
    const RenderKey a = (page: 0, scale: 1.0, tile: null);
    const RenderKey b = (page: 1, scale: 1.0, tile: null);
    const RenderKey c = (page: 0, scale: 2.0, tile: null);
    const RenderKey d = (page: 0, scale: 1.0, tile: Rect.fromLTWH(0, 0, .5, .5));
    expect({a, b, c, d}.length, 4);
  });
}
