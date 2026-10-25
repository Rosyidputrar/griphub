import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/i18n.dart';
import 'package:griphub_agent/ui/theme.dart';

/// The shared relative-time helper (Tahap 4: replaces five private copies).
/// Language is a plain field on the Appearance singleton, so tests can flip
/// it without any device state.
void main() {
  tearDown(() => Appearance.instance.language = 'en');

  test('English branches', () {
    final now = DateTime.now();
    expect(formatAgo(now), 'just now');
    expect(formatAgo(now.subtract(const Duration(minutes: 5))), '5m ago');
    expect(formatAgo(now.subtract(const Duration(hours: 3))), '3h ago');
    expect(formatAgo(now.subtract(const Duration(days: 9))), '9d ago');
    expect(formatAgo(now.subtract(const Duration(days: 90))), '3mo ago');
    expect(formatAgo(now.subtract(const Duration(days: 800))), '2y ago');
  });

  test('Indonesian branches', () {
    Appearance.instance.language = 'id';
    final now = DateTime.now();
    expect(formatAgo(now), 'baru saja');
    expect(formatAgo(now.subtract(const Duration(minutes: 5))), '5 mnt lalu');
    expect(formatAgo(now.subtract(const Duration(hours: 3))), '3 jam lalu');
    expect(formatAgo(now.subtract(const Duration(days: 9))), '9 hr lalu');
    expect(formatAgo(now.subtract(const Duration(days: 90))), '3 bln lalu');
    expect(formatAgo(now.subtract(const Duration(days: 800))), '2 thn lalu');
  });
}
