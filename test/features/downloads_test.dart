import 'dart:async';
import 'dart:io';

import 'package:aerostream/app/providers.dart';
import 'package:aerostream/data/downloads/download_fetcher.dart';
import 'package:aerostream/domain/entities/download.dart';
import 'package:aerostream/domain/entities/enums.dart';
import 'package:aerostream/domain/entities/episode.dart';
import 'package:aerostream/domain/entities/media_item.dart';
import 'package:aerostream/domain/entities/stream_source.dart';
import 'package:aerostream/features/downloads/download_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// Writes [bytes] to the destination in [chunks] steps, reporting progress.
///
/// Deliberately touches the real filesystem: the parts of a downloader that
/// break are the parts that own files.
final class FakeDownloadFetcher implements DownloadFetcher {
  FakeDownloadFetcher({this.bytes = 2048, this.chunks = 4});

  final int bytes;
  final int chunks;

  /// Every call, in order, for assertions about retries.
  final List<Uri> calls = <Uri>[];
  final List<Map<String, String>> headersSeen = <Map<String, String>>[];

  /// When set, the download fails with this error instead of writing.
  Object? failure;

  /// When set, `download` waits for this before finishing, so a test can cancel
  /// a download that is genuinely in flight.
  Completer<void>? gate;

  @override
  Future<int> download({
    required Uri url,
    required Map<String, String> headers,
    required String destination,
    required DownloadTicket ticket,
    required void Function(int received, int? total) onProgress,
  }) async {
    calls.add(url);
    headersSeen.add(headers);
    final file = File(destination);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(const <int>[]);

    if (failure != null) throw failure!;

    const step = 512;
    var written = 0;
    for (var i = 0; i < chunks; i++) {
      if (ticket.isCancelled) throw const DownloadCancelled();
      written = (written + step).clamp(0, bytes);
      await file.writeAsBytes(List<int>.filled(written, 0));
      onProgress(written, bytes);
      await Future<void>.delayed(Duration.zero);
    }
    if (gate != null) await gate!.future;
    if (ticket.isCancelled) {
      throw const DownloadCancelled();
    }
    return written;
  }
}

MediaItem movie({String id = 'p:movie', String title = 'The Quiet Hour'}) =>
    MediaItem(
      id: id,
      pluginId: 'p',
      title: title,
      type: MediaType.movie,
      url: 'https://example.test/$id',
    );

StreamSource source({
  String url = 'https://cdn.example.test/film.mp4',
  bool isHls = false,
  bool isDash = false,
  Map<String, String> headers = const <String, String>{},
}) =>
    StreamSource(url: url, isHls: isHls, isDash: isDash, headers: headers);

typedef Harness = ({
  ProviderContainer container,
  InMemorySettingsStore store,
  Directory directory,
  FakeDownloadFetcher fetcher,
});

Harness harness({FakeDownloadFetcher? fetcher, InMemorySettingsStore? store}) {
  final settings = store ?? InMemorySettingsStore();
  final directory = Directory.systemTemp.createTempSync('aerostream-dl-');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  final fake = fetcher ?? FakeDownloadFetcher();
  final container = ProviderContainer(
    overrides: [
      settingsStoreProvider.overrideWithValue(settings),
      downloadDirectoryProvider.overrideWithValue(directory),
      downloadFetcherProvider.overrideWithValue(fake),
    ],
  );
  addTearDown(container.dispose);
  return (
    container: container,
    store: settings,
    directory: directory,
    fetcher: fake,
  );
}

void main() {
  group('link classification', () {
    test('only progressive HTTP links count as downloadable', () {
      expect(isDownloadableLink('https://cdn.test/a.mp4'), true);
      expect(isDownloadableLink('http://cdn.test/a.mkv'), true);
      expect(isDownloadableLink('https://cdn.test/live.m3u8'), false);
      expect(isDownloadableLink('https://cdn.test/manifest.mpd'), false);
      expect(isDownloadableLink('https://cdn.test/a.mp4', isHls: true), false);
      expect(isDownloadableLink('https://cdn.test/a.mp4', isDash: true), false);
      expect(isDownloadableLink('magnet:?xt=urn'), false);
      expect(isDownloadableLink('file:///sdcard/a.mp4'), false);
    });

    test('extension and file name are safe', () {
      expect(extensionForUrl('https://cdn.test/a/b.MP4?token=1'), 'mp4');
      expect(extensionForUrl('https://cdn.test/stream'), 'bin');
      expect(extensionForUrl('https://cdn.test/a.verylongext'), 'bin');
      expect(
        downloadFileName(title: 'The Quiet Hour!', extension: 'mp4'),
        'the-quiet-hour.mp4',
      );
      expect(
        downloadFileName(title: '   ', extension: 'mp4'),
        'download.mp4',
      );
    });
  });

  group('DownloadsController', () {
    test('queues and completes a download, writing the file', () async {
      final h = harness();
      final controller = h.container.read(downloadsProvider.notifier);
      final task = await controller.enqueue(item: movie(), source: source());

      expect(task.status, DownloadStatus.queued);
      // Let the (fake) transfer finish.
      await pumpUntil(
          () => h.container.read(downloadsProvider).first.isPlayable);

      final done = h.container.read(downloadsProvider).single;
      expect(done.status, DownloadStatus.complete);
      expect(done.receivedBytes, 2048);
      expect(done.progress, 1.0);
      expect(File(controller.pathFor(done)).existsSync(), true);
      expect(h.fetcher.calls, [Uri.parse('https://cdn.example.test/film.mp4')]);
    });

    test('passes plugin headers through to the request', () async {
      final h = harness();
      final controller = h.container.read(downloadsProvider.notifier);
      await controller.enqueue(
        item: movie(),
        source: source(headers: {'Referer': 'https://origin.test'}),
      );
      await pumpUntil(
          () => h.container.read(downloadsProvider).first.isPlayable);
      expect(h.fetcher.headersSeen.single, {'Referer': 'https://origin.test'});
    });

    test('refuses playlists and says why', () async {
      final h = harness();
      final controller = h.container.read(downloadsProvider.notifier);

      await expectLater(
        controller.enqueue(item: movie(), source: source(isHls: true)),
        throwsA(
          isA<DownloadRejected>().having(
            (rejection) => rejection.message,
            'message',
            contains('playlist'),
          ),
        ),
      );
      await expectLater(
        controller.enqueue(
          item: movie(),
          source: source(url: 'https://cdn.test/x.mpd'),
        ),
        throwsA(isA<DownloadRejected>()),
      );
      expect(h.container.read(downloadsProvider), isEmpty);
      expect(h.fetcher.calls, isEmpty);
    });

    test('one task per title, and no duplicate queueing', () async {
      final h =
          harness(fetcher: FakeDownloadFetcher()..gate = Completer<void>());
      final controller = h.container.read(downloadsProvider.notifier);
      final item = movie();

      await controller.enqueue(item: item, source: source());
      await expectLater(
        controller.enqueue(item: item, source: source()),
        throwsA(
          isA<DownloadRejected>().having(
            (rejection) => rejection.message,
            'message',
            contains('already downloading'),
          ),
        ),
      );
      expect(h.container.read(downloadsProvider), hasLength(1));
      await controller.cancel(h.container.read(downloadsProvider).single.id);
    });

    test('an episode is its own task', () async {
      final h = harness();
      final controller = h.container.read(downloadsProvider.notifier);
      final show = movie(id: 'p:show', title: 'Slow River');
      await controller.enqueue(
        item: show,
        episode: const Episode(id: 's1e1', url: 'u1', number: 1),
        source: source(url: 'https://cdn.test/e1.mp4'),
      );
      await controller.enqueue(
        item: show,
        episode: const Episode(id: 's1e2', url: 'u2', number: 2),
        source: source(url: 'https://cdn.test/e2.mp4'),
      );
      await pumpUntil(
          () => h.container.read(downloadsProvider).every((t) => t.isPlayable));
      expect(h.container.read(downloadsProvider), hasLength(2));
      expect(
        h.container.read(downloadsProvider).map((task) => task.title),
        ['Slow River · S01E02', 'Slow River · S01E01'],
      );
    });

    test('cancelling stops the transfer, deletes the file and keeps the task',
        () async {
      final h =
          harness(fetcher: FakeDownloadFetcher()..gate = Completer<void>());
      final controller = h.container.read(downloadsProvider.notifier);
      final task = await controller.enqueue(item: movie(), source: source());

      await pumpUntil(
        () => h.container.read(downloadsProvider).single.receivedBytes > 0,
      );
      await controller.cancel(task.id);
      h.fetcher.gate!.complete();

      await pumpUntil(
        () =>
            h.container.read(downloadsProvider).single.status ==
            DownloadStatus.paused,
      );
      final paused = h.container.read(downloadsProvider).single;
      expect(paused.receivedBytes, 0);
      expect(File(controller.pathFor(paused)).existsSync(), false);
    });

    test('a failed transfer keeps the reason and leaves no partial file',
        () async {
      final h = harness(
        fetcher: FakeDownloadFetcher()..failure = const SocketException('down'),
      );
      final controller = h.container.read(downloadsProvider.notifier);
      await controller.enqueue(item: movie(), source: source());

      await pumpUntil(
        () =>
            h.container.read(downloadsProvider).single.status ==
            DownloadStatus.failed,
      );
      final failed = h.container.read(downloadsProvider).single;
      expect(failed.error, isNotNull);
      expect(failed.receivedBytes, 0);
      expect(File(controller.pathFor(failed)).existsSync(), false);

      // Retrying works once the cause is gone.
      h.fetcher.failure = null;
      await controller.startDownload(failed.id);
      expect(h.container.read(downloadsProvider).single.status,
          DownloadStatus.complete);
    });

    test('reload marks an interrupted transfer paused, not running', () async {
      final store = InMemorySettingsStore();
      final first = harness(store: store);
      final controller = first.container.read(downloadsProvider.notifier);
      await controller.enqueue(item: movie(), source: source());
      await pumpUntil(
        () => first.container.read(downloadsProvider).single.isPlayable,
      );

      // Pretend the process died mid-transfer.
      final corrupt = store.values[DownloadsController.storageKey]!.replaceAll(
        '"status":"complete"',
        '"status":"running"',
      );
      store.values[DownloadsController.storageKey] = corrupt;

      final reloaded = harness(store: store);
      final task = reloaded.container.read(downloadsProvider).single;
      expect(task.status, DownloadStatus.paused);
      expect(task.receivedBytes, 0);
    });

    test('remove deletes the file and the entry; removeFinished clears done',
        () async {
      final h = harness();
      final controller = h.container.read(downloadsProvider.notifier);
      await controller.enqueue(item: movie(id: 'p:1'), source: source());
      await controller.enqueue(
        item: movie(id: 'p:2', title: 'Second'),
        source: source(url: 'https://cdn.test/b.mp4'),
      );
      await pumpUntil(
        () => h.container
            .read(downloadsProvider)
            .every((task) => task.isPlayable),
      );

      final first = h.container.read(downloadsProvider).first;
      final firstPath = controller.pathFor(first);
      await controller.remove(first.id);
      expect(File(firstPath).existsSync(), false);
      expect(h.container.read(downloadsProvider), hasLength(1));

      await controller.removeFinished();
      expect(h.container.read(downloadsProvider), isEmpty);
      expect(h.directory.listSync(), isEmpty);
    });

    test('a finished download is offered as a playable file source', () async {
      final h = harness();
      final controller = h.container.read(downloadsProvider.notifier);
      await controller.enqueue(item: movie(), source: source());
      await pumpUntil(
        () => h.container.read(downloadsProvider).single.isPlayable,
      );
      final task = h.container.read(downloadsProvider).single;
      final playable = controller.playableSource(task);
      expect(playable.url, startsWith('file://'));
      expect(playable.url, endsWith(task.fileName));
      expect(playable.isHls, false);
    });

    test('a corrupt queue payload loads empty', () {
      final store = InMemorySettingsStore()
        ..values[DownloadsController.storageKey] = '[]]';
      final h = harness(store: store);
      expect(h.container.read(downloadsProvider), isEmpty);
    });
  });
}

/// Pumps the event loop until [condition] holds, or fails after a second.
Future<void> pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition never became true');
}
