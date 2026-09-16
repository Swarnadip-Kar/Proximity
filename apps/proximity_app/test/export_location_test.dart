// Export default location: resolver/fallback/store/file unité contracts.
//
// Covers the pure pieces (normalize / display / resolveExportDir with
// injected fetchers), the DeviceStore roundtrip (memory backend; the
// secure backend shares the same prefs key), and the io save path with
// an explicit directory (content + filename bytes untouched — only WHERE
// the file lands is new).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/export_location.dart';
import 'package:proximity_app/core/file_saver.dart';

void main() {
  group('normalizeExportDir', () {
    test('blank reads as no custom location', () {
      expect(normalizeExportDir(null), isNull);
      expect(normalizeExportDir(''), isNull);
      expect(normalizeExportDir('   '), isNull);
    });

    test('trims a real path', () {
      expect(normalizeExportDir('  /a/b  '), '/a/b');
    });
  });

  group('exportDirDisplayName', () {
    test('missing reads as the system default label', () {
      expect(exportDirDisplayName(null), 'Downloads (system default)');
      expect(exportDirDisplayName(''), 'Downloads (system default)');
      expect(exportDirDisplayName('  '), 'Downloads (system default)');
    });

    test('stored path shows verbatim', () {
      expect(exportDirDisplayName('/a/b'), '/a/b');
    });
  });

  group('resolveExportDir', () {
    test('custom directory wins over Downloads', () async {
      expect(
        await resolveExportDir(
          customDir: '/custom',
          getDownloadsPath: () async => '/downloads',
          getDocumentsPath: () async => '/docs',
        ),
        '/custom',
      );
    });

    test('blank custom falls back to Downloads', () async {
      expect(
        await resolveExportDir(
          customDir: '   ',
          getDownloadsPath: () async => '/downloads',
          getDocumentsPath: () async => '/docs',
        ),
        '/downloads',
      );
    });

    test('missing Downloads falls back to documents', () async {
      expect(
        await resolveExportDir(
          getDownloadsPath: () async => null,
          getDocumentsPath: () async => '/docs',
        ),
        '/docs',
      );
    });

    test('throwing Downloads lookup falls back to documents', () async {
      expect(
        await resolveExportDir(
          getDownloadsPath: () async => throw StateError('nope'),
          getDocumentsPath: () async => '/docs',
        ),
        '/docs',
      );
    });

    test('no Downloads fetcher uses documents', () async {
      expect(
        await resolveExportDir(
          getDocumentsPath: () async => '/docs',
        ),
        '/docs',
      );
    });
  });

  group('DeviceStore export dir (memory backend)', () {
    test('absent reads as null', () async {
      expect(await InMemoryDeviceStore().readExportDir(), isNull);
    });

    test('write/read/clear roundtrip persists the path', () async {
      final store = InMemoryDeviceStore();
      await store.writeExportDir('/exports');
      expect(await store.readExportDir(), '/exports');
      await store.clearExportDir();
      expect(await store.readExportDir(), isNull);
    });

    test('blank writes are ignored', () async {
      final store = InMemoryDeviceStore();
      await store.writeExportDir('   ');
      expect(await store.readExportDir(), isNull);
    });
  });

  group('saveTextFile routing (io)', () {
    test('explicit directory wins; bytes + name untouched', () async {
      final tmp =
          await Directory.systemTemp.createTemp('prox_export_test');
      try {
        const csv = 'Name,ID Number,Email,Status\nA,1,a@x.in,Present\n';
        final path = await saveTextFile('attendance_X.csv', csv,
            directory: tmp.path);
        expect(path, '${tmp.path}/attendance_X.csv');
        final back = await File(path).readAsString();
        expect(back, csv);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('isExportDirWritable: real dir true, blank false', () async {
      final tmp =
          await Directory.systemTemp.createTemp('prox_writable_test');
      try {
        expect(await isExportDirWritable(tmp.path), isTrue);
      } finally {
        await tmp.delete(recursive: true);
      }
      expect(await isExportDirWritable('   '), isFalse);
    });
  });
}
