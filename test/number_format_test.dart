import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/i18n.dart';
import 'package:griphub_agent/ui/theme.dart';

void main() {
  tearDown(() => Appearance.instance.language = 'en');

  test('numbers use dot thousands and a decimal comma in Indonesian', () {
    Appearance.instance.language = 'id';
    expect(localNumber('7350'), '7.350');
    expect(localNumber('0.978'), '0,978');
    expect(localNumber('1234567.5'), '1.234.567,5');
    expect(localNumber('1.2M'), '1,2M');
    expect(localNumber('959k'), '959k');
  });

  test('numbers use comma thousands and a decimal point in English', () {
    Appearance.instance.language = 'en';
    expect(localNumber('7350'), '7,350');
    expect(localNumber('0.978'), '0.978');
    expect(localNumber('-1500'), '-1,500');
  });

  test('text that is not a number is left alone', () {
    expect(localNumber(r'$0.00'), r'$0.00');
    expect(localNumber('—'), '—');
  });

  test('typed numbers are read in the app language', () {
    Appearance.instance.language = 'id';
    expect(parseLocalNumber('1,5'), 1.5);
    expect(parseLocalNumber('1.000'), 1000);
    expect(parseLocalNumber(' 2 '), 2);
    expect(parseLocalNumber('abc'), isNull);
    Appearance.instance.language = 'en';
    expect(parseLocalNumber('1.5'), 1.5);
    expect(parseLocalNumber('1,000'), 1000);
  });
}
