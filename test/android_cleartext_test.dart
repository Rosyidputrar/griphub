import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The preview opens pages over plain http on the phone's loopback, and Android refuses cleartext traffic unless the
/// app says otherwise. It did not, so every preview of a dev server or a served page failed before connecting. This
/// reads the Android files themselves (a real WebView cannot run in a test): the policy must be wired in, and must
/// open the loopback only.
void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final config = File('android/app/src/main/res/xml/network_security_config.xml').readAsStringSync();

  test('the app points at a network security config', () {
    expect(manifest, contains('android:networkSecurityConfig="@xml/network_security_config"'));
  });

  test('cleartext is not opened for everything, in the manifest or the config', () {
    expect(manifest, isNot(contains('usesCleartextTraffic="true"')));
    expect(RegExp(r'<base-config[^>]*cleartextTrafficPermitted="false"').hasMatch(config), isTrue);
    expect(RegExp(r'<base-config[^>]*cleartextTrafficPermitted="true"').hasMatch(config), isFalse);
  });

  test('only the phone\'s own loopback may be reached in the clear', () {
    final allowed = RegExp(r'<domain-config[^>]*cleartextTrafficPermitted="true"[^>]*>(.*?)</domain-config>', dotAll: true);
    final hosts = <String>[
      for (final block in allowed.allMatches(config))
        for (final d in RegExp(r'<domain[^>]*>([^<]+)</domain>').allMatches(block.group(1)!)) d.group(1)!.trim(),
    ];
    expect(hosts, unorderedEquals(['127.0.0.1', 'localhost']));
    expect(config, isNot(contains('includeSubdomains="true"')), reason: 'no subdomains of anything');
  });

  test('the preview\'s hosts are the ones allowed', () {
    // remote_mode.dart builds every preview URL on 127.0.0.1; a dev server on this phone is on localhost.
    final remote = File('lib/agent/remote_mode.dart').readAsStringSync();
    for (final m in RegExp(r"http://([^:/$']+)").allMatches(remote)) {
      expect(['127.0.0.1', 'localhost'], contains(m.group(1)), reason: 'a preview URL on ${m.group(1)}');
    }
  });
}
