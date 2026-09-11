// CSV export header schema: `Prof Name` / `Class Name` / `Prof Email`
// top rows, body bytes unchanged.
//
// Covers the shared builder used by every CSV export entry point
// (per-session preview, combined/selected matrix, date-range matrix,
// course-overview selected-dates matrix): all flow through `exportHeader`
// / `withExportHeader` in export_center_screen.dart. Body builders
// (`toCsv`, `buildDateRangeMatrix`) are untouched — P/A intersection,
// email keys, and sorting stay byte-identical.
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/records/export_center_screen.dart'
    show exportHeader;
import 'package:proximity_storage/storage.dart';

void main() {
  test('exportHeader prepends Prof Name/Class Name/Prof Email rows', () {
    const body = 'Name,ID Number,Email,Status\nA,1,a@x.in,Present\n';
    final csv = exportHeader(
      body,
      profName: 'Dr Ada',
      className: 'CS201',
      profEmail: 'ada@univ.edu',
    );
    expect(
      csv,
      'Prof Name,Dr Ada\n'
      'Class Name,CS201\n'
      'Prof Email,ada@univ.edu\n'
      'Name,ID Number,Email,Status\n'
      'A,1,a@x.in,Present\n',
    );
  });

  test('header builder is deterministic (shared by all entry points)', () {
    const body = 'Name,ID Number,Email,Status\nA,1,a@x.in,Present\n';
    // All four export entry points (per-session, combined/selected,
    // date-range, overview selected-dates) flow through `exportHeader`
    // (the State-local `withExportHeader` delegates verbatim) — same
    // args must yield byte-identical output.
    expect(
      exportHeader(body,
          profName: 'Dr Ada',
          className: 'CS201',
          profEmail: 'ada@univ.edu'),
      exportHeader(body,
          profName: 'Dr Ada',
          className: 'CS201',
          profEmail: 'ada@univ.edu'),
    );
  });

  test('per-session body bytes unchanged under the new header', () {
    final r = ClassRecord(
      id: 's1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-04',
      timestampIso: '2026-09-04T10:00:00.000Z',
      windows: [
        {'a@x.in': true}
      ],
      names: const {'a@x.in': 'A'},
      rolls: const {'a@x.in': '1'},
    );
    final body = r.toCsv();
    expect(body, 'Name,ID Number,Email,Status\nA,1,a@x.in,Present\n');
    final csv = exportHeader(body,
        profName: 'Prof', className: r.classLabel, profEmail: 'p@univ.edu');
    expect(csv.startsWith('Prof Name,Prof\nClass Name,CS201\nProf Email,p@univ.edu\n'),
        isTrue);
    // Body after the 3 header lines is byte-identical.
    final stripped = csv.split('\n').skip(3).join('\n');
    expect(stripped, body);
  });

  test('matrix body bytes unchanged under the new header', () {
    final s1 = ClassRecord(
      id: 'm1',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-04',
      timestampIso: '2026-09-04T10:00:00.000Z',
      windows: [
        {'a@x.in': true, 'b@x.in': true}
      ],
      names: const {'a@x.in': 'A', 'b@x.in': 'B'},
      rolls: const {'a@x.in': '1', 'b@x.in': '2'},
    );
    final s2 = ClassRecord(
      id: 'm2',
      courseId: 'CS201',
      classLabel: 'CS201',
      dateIso: '2026-09-05',
      timestampIso: '2026-09-05T10:00:00.000Z',
      windows: [
        {'a@x.in': true},
        {'a@x.in': false}
      ],
      names: const {'a@x.in': 'A'},
      rolls: const {'a@x.in': '1'},
    );
    final body = buildDateRangeMatrix([s2, s1]);
    expect(
      body,
      'Name,ID Number,Email,2026-09-04,2026-09-05\n'
      'A,1,a@x.in,P,A\n'
      'B,2,b@x.in,P,A\n',
    );
    final csv = exportHeader(body,
        profName: 'Prof', className: 'CS201', profEmail: 'p@univ.edu');
    final stripped = csv.split('\n').skip(3).join('\n');
    expect(stripped, body);
  });

  test('header escaping matches body: raw interpolation, no quoting', () {
    // Same contract as the old org line and the body builders — values
    // interpolate verbatim (commas pass through unquoted).
    final csv = exportHeader(
      'Name,ID Number,Email,Status\n',
      profName: 'Last, First',
      className: 'CS201',
      profEmail: 'p@univ.edu',
    );
    expect(csv.startsWith('Prof Name,Last, First\n'), isTrue);
  });

  test('empty prof identity emits empty fields (no legacy fallback)', () {
    final csv = exportHeader(
      'Name,ID Number,Email,Status\n',
      profName: '',
      className: 'CS201',
      profEmail: '',
    );
    expect(
      csv,
      'Prof Name,\nClass Name,CS201\nProf Email,\nName,ID Number,Email,Status\n',
    );
  });
}
