import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/models.dart';

/// Favorites keep starring order (not catalog order) and skip keys whose
/// model left the catalog; storage keeps those keys, so this only filters
/// what the sheet shows.
void main() {
  ModelInfo model(String provider, String id) => ModelInfo({
    'provider': provider,
    'id': id,
    'name': id,
  });

  test('follows starring order, not catalog order', () {
    final models = [model('griphub', 'a'), model('griphub', 'b'), model('griphub', 'c')];
    final favs = favoriteModelsInOrder(models, ['griphub/c', 'griphub/a']);
    expect(favs.map((m) => m.key).toList(), ['griphub/c', 'griphub/a']);
  });

  test('skips keys missing from the catalog', () {
    final models = [model('griphub', 'a')];
    final favs = favoriteModelsInOrder(models, ['griphub/gone', 'griphub/a']);
    expect(favs.map((m) => m.key).toList(), ['griphub/a']);
  });

  test('dedupes repeated keys and handles empty input', () {
    final models = [model('griphub', 'a')];
    expect(favoriteModelsInOrder(models, ['griphub/a', 'griphub/a']).length, 1);
    expect(favoriteModelsInOrder(models, []), isEmpty);
    expect(favoriteModelsInOrder([], ['griphub/a']), isEmpty);
  });
}
