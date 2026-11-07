import 'package:flutter/foundation.dart';

/// Which window shows the app (Fitur 4): the main one, or the floating panel over another app. Both show the same
/// engine, so the same chat; the panel is the app in a smaller form, not a copy of it.
class PanelState extends ChangeNotifier {
  PanelState._();
  static final instance = PanelState._();

  /// "app" or "panel".
  String surface = 'app';

  /// The text the panel was opened with from another app's selection ("Tanya GripHub"), if any.
  String? selection;

  /// Whether that app takes a replacement for the selection back.
  bool writable = false;

  bool get isPanel => surface == 'panel';

  void apply(Map<String, dynamic> event) {
    surface = event['surface'] as String? ?? 'app';
    selection = event['selection'] as String?;
    writable = event['writable'] == true;
    notifyListeners();
  }

  /// For tests: back to the main window.
  @visibleForTesting
  void reset() {
    surface = 'app';
    selection = null;
    writable = false;
    notifyListeners();
  }
}
