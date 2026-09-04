import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_storage/storage.dart';

void main() {
  test('enrollment roundtrip', () async {
    final store = InMemoryDeviceStore();
    expect(await store.readEnrollment(), isNull);
    final e = StoredEnrollment(
      email: 'a@x.in',
      name: 'A',
      roll: '1',
      seedHex: 'ab' * 32,
      pkHex: 'cd' * 32,
      templateCsv: '1.0,0.0',
      enrolledAt: DateTime.utc(2026, 1, 1),
    );
    await store.writeEnrollment(e);
    final back = (await store.readEnrollment())!;
    expect(back.email, 'a@x.in');
    expect(back.template, [1.0, 0.0]);
    await store.clearEnrollment();
    expect(await store.readEnrollment(), isNull);
  });

  test('history roundtrip + CSV export', () async {    final store = InMemoryDeviceStore();
    expect(await store.readHistory(), isEmpty);
    await store.appendHistory(ClassRecord(
      classLabel: 'CS201',
      dateIso: '2026-09-04',
      w1: {'a@x.in': true},
      w2: {'a@x.in': true},
      names: {'a@x.in': 'A'},
      rolls: {'a@x.in': '1'},
    ));
    final h = await store.readHistory();
    expect(h.length, 1);
    expect(h.first.w1Count, 1);
    expect(h.first.toCsv(), contains('A,1,a@x.in,1,1,Present'));
  });

  test('class catalog dedups + trims', () async {
    final store = InMemoryDeviceStore();
    expect(await store.readCatalog(), isEmpty);
    await store.addClass('  ');
    await store.addClass('CS201-Room301');
    await store.addClass('CS201-Room301');
    await store.addClass('CS202-Room302');
    expect(await store.readCatalog(),
        ['CS201-Room301', 'CS202-Room302']);
  });

  test('rename course migrates sessions', () async {
    final store = InMemoryDeviceStore();
    await store.addCourse('CS201');
    await store.appendHistory(ClassRecord(
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-03',
      w1: const {},
      w2: const {},
      names: const {},
      rolls: const {},
    ));
    expect(await store.renameCourse('CS201', 'CS201-A'), isTrue);
    expect(
        (await store.readCourses()).map((c) => c.name), ['CS201-A']);
    final h = await store.readHistory();
    expect(h.single.courseId, 'CS201-A');
    expect(h.single.classLabel, 'CS201-A');
    expect(await store.renameCourse('CS201-A', 'CS201-A'), isFalse);
    expect(await store.renameCourse('CS201-A', '  '), isFalse);
    expect(await store.renameCourse('Missing', 'X'), isFalse);
  });

  test('host name roundtrip', () async {
    final store = InMemoryDeviceStore();
    expect(await store.readHostName(), '');
    await store.writeHostName(' Prof K ');
    expect(await store.readHostName(), 'Prof K');
  });
}
