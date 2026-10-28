/// A sentence for the user: English with `{name}` placeholders, and their values. Screens show it in the app's language
/// (`trMsg` in lib/ui/i18n.dart, which translates the English and then fills it in); logs and tests read it in English.
class Msg {
  const Msg(this.en, [this.args = const {}]);

  final String en;
  final Map<String, Object?> args;

  /// [text] (the English, or its translation) with the placeholders filled in.
  String fill(String text) {
    var s = text;
    args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
    return s;
  }

  @override
  String toString() => fill(en);
}
