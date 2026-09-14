// Class-number ordinal pins (browse tile disc caption + roster header).
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/widgets/class_ordinal.dart';

void main() {
  test('ordinalSuffix handles teens + tens', () {
    expect(ordinalSuffix(1), 'st');
    expect(ordinalSuffix(2), 'nd');
    expect(ordinalSuffix(3), 'rd');
    expect(ordinalSuffix(4), 'th');
    expect(ordinalSuffix(11), 'th');
    expect(ordinalSuffix(12), 'th');
    expect(ordinalSuffix(13), 'th');
    expect(ordinalSuffix(21), 'st');
    expect(ordinalSuffix(22), 'nd');
    expect(ordinalSuffix(23), 'rd');
    expect(ordinalSuffix(101), 'st');
    expect(ordinalSuffix(111), 'th');
  });

  test('classOrdinalLabel words + hides unknown', () {
    expect(classOrdinalLabel(1), '1st Class');
    expect(classOrdinalLabel(2), '2nd Class');
    expect(classOrdinalLabel(3), '3rd Class');
    expect(classOrdinalLabel(12), '12th Class');
    expect(classOrdinalLabel(0), '');
    expect(classOrdinalLabel(-1), '');
  });
}
