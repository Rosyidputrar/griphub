/// The app's idea of "now", for text relative to it ("5m ago", "expires in 3 days", today's bar).
/// Tests pin it (test/golden/harness.dart), so those texts render the same whatever day they run.
DateTime Function() clock = DateTime.now;
