import 'package:aerostream/data/maintenance/plugin_data_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  late InMemorySettingsStore settings;
  late PluginDataStore store;

  setUp(() {
    settings = InMemorySettingsStore();
    store = PluginDataStore(settings);
  });

  test('counts only plugin-owned keys', () async {
    await settings.setString('plugin.dev.one.token', 'secret');
    await settings.setString('plugin.dev.one.endpoint', 'https://mirror');
    await settings.setString('playback.preferredQuality', '1080p');
    await settings.setString('library.items', '[]');

    expect(store.stored(), hasLength(2));
    expect(store.stored().keys, everyElement(startsWith('plugin.')));
  });

  test('deletes plugin data and leaves preferences, library, history alone',
      () async {
    await settings.setString('plugin.dev.one.token', 'secret');
    await settings.setString('plugin.dev.two.session', 'abc');
    await settings.setString('playback.autoplayNext', 'true');
    await settings.setString('library.items', '[{"id":1}]');
    await settings.setString('history.entries', '[{"id":1}]');

    final removed = await store.forgetAll();

    expect(removed, 2);
    expect(store.stored(), isEmpty);
    expect(settings.values.keys, <String>[
      'playback.autoplayNext',
      'library.items',
      'history.entries',
    ]);
  });

  test('is a no-op on an empty store', () async {
    expect(await store.forgetAll(), 0);
    expect(settings.values, isEmpty);
  });

  test('the count shrinks after a delete, so the UI updates', () async {
    await settings.setString('plugin.dev.one.token', 'secret');
    expect(store.stored(), hasLength(1));

    await store.forgetAll();

    expect(store.stored(), isEmpty);
  });
}
