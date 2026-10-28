import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../agent/agent_controller.dart';
import 'kit.dart';
import 'terminal_pane.dart';
import 'i18n.dart';
import 'theme.dart';

/// A shell with the agent's toolchain (git, ssh, node…). Sessions outlive the
/// screen, so leaving and coming back resumes the same tabs.
class ShellSession {
  ShellSession._(
    this.pty,
    this.cwd,
    this.title, {
    required this.linux,
    this.remoteSession,
    this.remoteKill,
    this.remoteEnv = const {},
  });

  /// Every open tab, in strip order.
  static final sessions = <ShellSession>[];

  /// Index of the tab shown when the screen opens.
  static int selected = 0;

  /// Commands typed in any tab, newest first (best effort, from keystrokes).
  static final history = <String>[];

  /// Bumped when a session exits or the list changes, so open screens redraw.
  static final changes = ValueNotifier<int>(0);

  final Pty pty;
  String cwd;
  String title;

  /// Started with `box`: the Linux container, where cd-to-project doesn't apply.
  final bool linux;

  /// With a server agent: the name of the tmux session on the server this tab shows, and how to end it.
  final String? remoteSession;
  final List<String>? remoteKill;
  final Map<String, String> remoteEnv;

  bool get remote => remoteSession != null;
  final terminal = Terminal(maxLines: 10000);
  bool exited = false;

  /// How the shell (or on a server, ssh) ended; null while it runs.
  int? exitCode;

  /// A server tab that lost its connection (ssh ends with 255 then), rather than one whose shell was exited: its tmux
  /// session is still running there.
  bool get connectionLost => remote && exitCode == 255;
  String _line = '';

  /// Tail of what the shell actually printed, for the two guards below.
  String _outputTail = '';

  /// [rejoin]: on a server, the tmux session to join again (a tab whose connection dropped); otherwise a new one.
  static Future<ShellSession> start(
    AgentController agent,
    String cwd, {
    String? title,
    bool linux = false,
    String? rejoin,
  }) async {
    final env = await agent.client.environment();
    final home = env['HOME']!;
    if (agent.remote.active && agent.remote.setup != null) {
      return _startRemote(agent, env, cwd, title, linux, rejoin);
    }
    // mksh reads $ENV for interactive shells: a short prompt and a few aliases.
    final rc = File('$home/.griphubrc');
    rc.writeAsStringSync(r'''
PS1='${PWD##*/} $ '
alias ll='ls -la'
alias la='ls -A'
alias gs='git status'
''');
    final pty = Pty.start(
      '/system/bin/sh',
      arguments: ['-i'],
      workingDirectory: cwd,
      environment: {...env, 'TERM': 'xterm-256color', 'ENV': rc.path},
      rows: 40,
      columns: 80,
    );
    final session = ShellSession._(pty, cwd, title ?? (linux ? 'linux' : 'sh'), linux: linux);
    session._wire();
    return session;
  }

  /// A tab on the server (server_agent.md, phase 6): ssh with a terminal, into a tmux session there. The shell keeps
  /// running when the connection drops or the app is closed; the next tab with the same session name (the first one
  /// after a restart gets the first name again) picks it up where it was. Closing a tab ends its session on the server.
  /// Adapted from CoderRa's server mode.
  static ShellSession _startRemote(
    AgentController agent,
    Map<String, String> env,
    String cwd,
    String? title,
    bool linux,
    String? rejoin,
  ) {
    final setup = agent.remote.setup!;
    final kind = linux ? 'box' : 'sh';
    var n = 1;
    while (sessions.any((s) => !s.exited && s.remoteSession == 'griphub-$kind-$n')) {
      n++;
    }
    final name = rejoin ?? 'griphub-$kind-$n';
    final argv = setup.terminalArgv(cwd: cwd, session: name, box: linux);
    final shellEnv = {...env, 'TERM': 'xterm-256color'};
    final pty = Pty.start(
      argv.first,
      arguments: argv.skip(1).toList(),
      workingDirectory: env['HOME'],
      environment: shellEnv,
      rows: 40,
      columns: 80,
    );
    final session = ShellSession._(
      pty,
      cwd,
      title ?? (linux ? 'linux' : 'sh'),
      linux: linux,
      remoteSession: name,
      remoteKill: setup.killTerminalArgv(name),
      remoteEnv: shellEnv,
    );
    session._wire();
    return session;
  }

  void _wire() {
    pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen((text) {
      terminal.write(text);
      _outputTail = (_outputTail + text);
      if (_outputTail.length > 2000) _outputTail = _outputTail.substring(_outputTail.length - 2000);
    });
    pty.exitCode.then((code) {
      exited = true;
      exitCode = code;
      terminal.write('\r\n[process exited with code $code]\r\n');
      changes.value++;
    });
    terminal.onOutput = input;
    terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
  }

  /// Keystrokes from the terminal view: sent to the shell and tracked for history.
  void input(String data) {
    _track(data);
    pty.write(const Utf8Encoder().convert(data));
  }

  void type(String text) => pty.write(const Utf8Encoder().convert(text));

  /// Types [command] followed by Enter and remembers it.
  void run(String command) {
    _remember(command);
    _line = '';
    type('$command\r');
  }

  /// Lets go of a server tab's connection; its tmux session keeps running there (and can be joined again).
  void detach() => pty.kill();

  /// Ends the tab: its shell here, or on a server its tmux session too.
  void kill() {
    pty.kill();
    final end = remoteKill;
    if (end != null) {
      // Best effort: if the server cannot be reached the session simply stays there until it is.
      unawaited(
        Process.run(end.first, end.skip(1).toList(), environment: remoteEnv).then<void>((_) {}, onError: (Object _) {}),
      );
    }
  }

  /// True when the screen's last non-empty line looks like this app's shell
  /// prompt (`<dir> $`, no user@host): a local shell waiting for input, not
  /// ssh (remote prompts carry @), vim, or a REPL. A server tab's shell has
  /// the same prompt (RemoteSetup.shellRc).
  bool get atShellPrompt {
    final buf = terminal.buffer;
    for (var i = buf.height - 1; i >= 0 && i >= buf.height - 50; i--) {
      final line = buf.lines[i].getText().trimRight();
      if (line.isEmpty) continue;
      return RegExp(r'^[^@]+ \$ *$').hasMatch(line);
    }
    return false;
  }

  void _track(String data) {
    data = data.replaceAll('\x1b[200~', '').replaceAll('\x1b[201~', '');
    // Arrow keys and other escape sequences: the shell may edit or recall a
    // line we can't see, so stop guessing until the next Enter.
    if (data.startsWith('\x1b')) {
      if (data.length > 1) _line = '';
      return;
    }
    for (final ch in data.runes) {
      if (ch == 0x0d || ch == 0x0a) {
        // Only remember lines the shell echoed back. A password prompt
        // (sudo, ssh, read -s) turns echo off, so the secret never lands
        // in history; a normal command is echoed before Enter is processed.
        if (_line.isNotEmpty && _outputTail.endsWith(_line)) _remember(_line);
        _line = '';
      } else if (ch == 0x7f || ch == 0x08) {
        if (_line.isNotEmpty) _line = String.fromCharCodes(_line.runes.toList()..removeLast());
      } else if (ch == 0x03 || ch == 0x15) {
        _line = '';
      } else if (ch >= 0x20) {
        _line += String.fromCharCode(ch);
      }
    }
  }

  static void _remember(String command) {
    final c = command.trim();
    if (c.isEmpty) return;
    history
      ..remove(c)
      ..insert(0, c);
    if (history.length > 30) history.removeRange(30, history.length);
  }
}

/// The selected text, without the padding spaces terminal lines carry.
String terminalSelectionText(Terminal terminal, TerminalController controller) {
  final range = controller.selection;
  if (range == null) return '';
  final lines = terminal.buffer.getText(range).split('\n').map((l) => l.trimRight()).toList();
  // Drop blank lines around the selection, but keep the first line's indentation.
  while (lines.isNotEmpty && lines.first.isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}

/// Selects the whole buffer, scrollback included.
void selectAllTerminal(Terminal terminal, TerminalController controller) {
  final buffer = terminal.buffer;
  if (buffer.height == 0) return;
  controller.setSelection(buffer.createAnchor(0, 0), buffer.createAnchor(buffer.viewWidth, buffer.height - 1));
}

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, required this.agent, this.command});
  final AgentController agent;

  /// Run in a new tab on open, e.g. `box` to enter the Linux container.
  final String? command;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  Object? error;
  bool starting = false;
  final focus = FocusNode();
  final controller = TerminalController();
  final tabScroll = ScrollController();
  bool ctrl = false;

  /// Font size; pinch with two fingers or A−/A+ to change it.
  double fontSize = Appearance.instance.terminalFontSize;
  final _pane = GlobalKey<TerminalPaneState>();

  /// Whether the selection toolbar shows: a selection in the buffer on screen, and not left over from a pinch.
  final _hasSelection = ValueNotifier(false);
  Buffer? _selectionBuffer;
  Terminal? _watched;

  AgentController get agent => widget.agent;
  List<ShellSession> get sessions => ShellSession.sessions;

  ShellSession? get session => sessions.isEmpty ? null : sessions[ShellSession.selected.clamp(0, sessions.length - 1)];

  String get _cwd => agent.cwd.isEmpty ? (agent.info['workspace'] as String? ?? '/') : agent.cwd;

  @override
  void initState() {
    super.initState();
    // Long-press (or drag) selects text; the selection toolbar follows it.
    controller.addListener(_refreshSelection);
    ShellSession.changes.addListener(_changed);
    _dropOtherMode();
    final command = widget.command;
    if (command != null || session == null) starting = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (command != null) {
        _newTab(command: command, linux: command.trim() == 'box');
      } else if (session == null) {
        _newTab();
      } else {
        _select(ShellSession.selected.clamp(0, sessions.length - 1));
      }
    });
  }

  /// Tabs of the other agent (this phone's shells after switching to the server, or the server's after switching back)
  /// are closed here. A server tab only lets go of its connection: its tmux session stays on the server, and the first
  /// tab after switching back joins it again.
  void _dropOtherMode() {
    final server = agent.remote.active;
    final other = [
      for (final s in sessions)
        if (s.remote != server) s,
    ];
    if (other.isEmpty) return;
    for (final s in other) {
      s.pty.kill();
      sessions.remove(s);
    }
    ShellSession.selected = 0;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ShellSession.changes.removeListener(_changed);
    controller.removeListener(_refreshSelection);
    _watched?.removeListener(_refreshSelection);
    _hasSelection.dispose();
    for (final s in sessions) {
      s.terminal.onOutput = s.input;
    }
    focus.dispose();
    controller.dispose();
    tabScroll.dispose();
    super.dispose();
  }

  /// Ctrl from the key bar applies to the next typed character.
  void _bind(ShellSession s) {
    s.terminal.onOutput = (data) {
      if (ctrl && data.length == 1) {
        final c = data.toLowerCase().codeUnitAt(0);
        if (c >= 0x61 && c <= 0x7a) data = String.fromCharCode(c - 0x60);
        if (mounted) setState(() => ctrl = false);
      }
      s.input(data);
    };
  }

  void _select(int i) {
    // A selection belongs to the tab it was made in.
    controller.clearSelection();
    final s = sessions[i];
    ShellSession.selected = i;
    _bind(s);
    // Follow the chat into its project — but only when the tab is sitting
    // at a local shell prompt. Typing cd into ssh, vim or a REPL sends the
    // text to that program instead (remote dir change, vim commands, or a
    // syntax error). The prompt check is a heuristic: our shells print
    // "<dir> $" (see ShellSession.start); anything else means "don't type".
    // When skipped, the tab keeps its old cwd and retries on the next switch.
    final cwd = _cwd;
    if (!s.linux && !s.exited && s.cwd != cwd && s.atShellPrompt) {
      s.type("cd '${cwd.replaceAll("'", r"'\''")}'\r");
      s.cwd = cwd;
    }
    setState(() {});
    focus.requestFocus();
  }

  Future<ShellSession?> _newTab({
    String? command,
    bool linux = false,
    String? title,
    int? replace,
    String? rejoin,
  }) async {
    setState(() {
      starting = true;
      error = null;
    });
    ShellSession s;
    try {
      s = await ShellSession.start(agent, _cwd, title: title, linux: linux, rejoin: rejoin);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e;
          starting = false;
        });
      }
      return null;
    }
    if (replace != null && replace < sessions.length) {
      sessions[replace] = s;
    } else {
      sessions.add(s);
    }
    final index = sessions.indexOf(s);
    ShellSession.changes.value++;
    // A server tab for the container already is the container's shell; typing `box` into it would nest one.
    if (command != null && !(s.remote && s.linux)) s.run(command);
    if (!mounted) return s;
    starting = false;
    _select(index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (tabScroll.hasClients) tabScroll.jumpTo(tabScroll.position.maxScrollExtent);
    });
    return s;
  }

  /// Closes tab [i]; a shell that is still running is only killed once confirmed.
  /// On a server, closing a tab ends its session there (even after the connection dropped), so it always asks.
  Future<void> _confirmClose(int i) async {
    final s = sessions[i];
    if (!s.exited || s.remote) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr(s.remote ? 'Close this tab and end its session on the server?' : 'Close this tab?')),
          content: Text(
            tr(
              s.remote
                  ? 'The shell on the server stops, with whatever is running in it. To only step away, leave the tab open: it keeps running on the server.'
                  : 'Its shell is still running and will be stopped.',
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Close tab'))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final index = sessions.indexOf(s);
    if (index >= 0) _close(index);
  }

  void _close(int i) {
    final s = sessions.removeAt(i);
    s.kill();
    // Closing a tab left of the open one shifts it down; keep the same tab open.
    if (i < ShellSession.selected) ShellSession.selected--;
    if (ShellSession.selected >= sessions.length) ShellSession.selected = sessions.length - 1;
    if (ShellSession.selected < 0) ShellSession.selected = 0;
    ShellSession.changes.value++;
    if (sessions.isNotEmpty) _select(ShellSession.selected);
  }

  Future<void> _restart() async {
    final s = session;
    if (s == null) {
      await _newTab();
      return;
    }
    final i = sessions.indexOf(s);
    controller.clearSelection();
    if (s.remote) {
      // A server tab joins its tmux session again: what ran in it is still there.
      s.detach();
      await _newTab(linux: s.linux, title: s.title, replace: i, rejoin: s.remoteSession);
      return;
    }
    s.kill();
    await _newTab(linux: s.linux, title: s.title, command: s.linux ? 'box' : null, replace: i);
  }

  Future<void> _rename(int i) async {
    final s = sessions[i];
    final field = TextEditingController(text: s.title);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Rename tab')),
        content: TextField(controller: field, autofocus: true, onSubmitted: (v) => Navigator.of(context).pop(v)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.of(context).pop(field.text), child: Text(tr('Rename'))),
        ],
      ),
    );
    field.dispose();
    if (name != null && name.trim().isNotEmpty) {
      s.title = name.trim();
      ShellSession.changes.value++;
    }
  }

  Future<void> _runTests() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final t = await agent.features.detectTests();
      if (t == null) {
        messenger.showSnackBar(SnackBar(content: Text(tr('No test setup found'))));
        return;
      }
      await _newTab(command: t.command, title: t.framework.isEmpty ? 'tests' : t.framework);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _key(TerminalKey key) {
    session?.terminal.keyInput(key, ctrl: ctrl);
    if (ctrl) setState(() => ctrl = false);
    focus.requestFocus();
  }

  void _text(String s) {
    session?.terminal.textInput(s);
    focus.requestFocus();
  }

  /// True when [s] may receive keystrokes sent on the user's behalf. At a
  /// local shell prompt they go to the shell; anywhere else (vim, less, ssh,
  /// a REPL, an exited shell) they would drive whatever program is running,
  /// so the user confirms first instead of the keystrokes going out silently.
  Future<bool> _confirmSendIfNeeded(ShellSession s) async {
    if (s.atShellPrompt) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Not at a shell prompt')),
        content: Text(
          tr(
            'This tab is not sitting at a local shell prompt. Sending this would type into whatever program is running here (for example vim, less, ssh, or a REPL) instead of the shell. Send it anyway?',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Send anyway'))),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _sshMenu() async {
    final hosts = agent.integrations.hosts;
    if (hosts.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('Add a server under Accounts & servers first'))));
      return;
    }
    final name = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        // Scrolls once there are more servers than fit.
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              for (final h in hosts)
                ListTile(
                  leading: const Icon(LucideIcons.server),
                  title: Text(h.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    h.address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: mono, fontSize: 12),
                  ),
                  onTap: () => Navigator.of(context).pop(h.name),
                ),
            ],
          ),
        ),
      ),
    );
    final s = session;
    if (name != null && s != null && await _confirmSendIfNeeded(s)) s.run('ssh $name');
    focus.requestFocus();
  }

  Future<void> _historySheet() async {
    final items = ShellSession.history;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('No commands yet'))));
      return;
    }
    final pick = await showModalBottomSheet<({String command, bool run})>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 0), child: SectionLabel(tr('Command history'))),
              for (final c in items)
                ListTile(
                  dense: true,
                  leading: const Icon(LucideIcons.history, size: 18),
                  // Full wrap: a long command drops down instead of being cut.
                  title: Text(c, style: const TextStyle(fontFamily: mono, fontSize: 13)),
                  // Tap inserts the command for editing; the play button runs it.
                  onTap: () => Navigator.of(context).pop((command: c, run: false)),
                  trailing: IconButton(
                    tooltip: tr('Run'),
                    icon: const Icon(LucideIcons.play, size: 18),
                    onPressed: () => Navigator.of(context).pop((command: c, run: true)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final s = session;
    if (pick != null && s != null) {
      if (pick.run) {
        if (await _confirmSendIfNeeded(s)) s.run(pick.command);
      } else {
        s.type(pick.command);
      }
    }
    focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final s = session;
    _watch(s?.terminal);
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('Terminal')),
            if (s != null)
              Text(
                s.linux
                    ? tr(s.remote ? 'The agent\'s box' : 'Linux container')
                    : s.cwd.replaceFirst(RegExp(r'^.*/files/home'), '~'),
                style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.muted),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: tr('Command history'),
            icon: const Icon(LucideIcons.history, size: 20),
            onPressed: _historySheet,
          ),
          IconButton(
            tooltip: tr('SSH to a server'),
            icon: const Icon(LucideIcons.server, size: 20),
            onPressed: _sshMenu,
          ),
          IconButton(
            tooltip: tr('Restart shell'),
            icon: const Icon(LucideIcons.rotateCcw, size: 20),
            onPressed: _restart,
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(preferredSize: const Size.fromHeight(49), child: _tabStrip(p)),
      ),
      body: error != null && s == null
          ? Center(child: Text('${tr('Could not start a shell')}: $error'))
          : s == null
          ? starting
                ? const Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : Center(
                    child: SizedBox(
                      width: 220,
                      child: PrimaryButton(label: tr('New shell'), icon: LucideIcons.plus, onPressed: () => _newTab()),
                    ),
                  )
          : Column(
              children: [
                if (s.connectionLost) ServerTabLostBar(onReconnect: _restart),
                Expanded(
                  child: TerminalPane(
                    key: _pane,
                    terminal: s.terminal,
                    controller: controller,
                    focusNode: focus,
                    fontSize: fontSize,
                    dark: dark,
                    theme: dark ? _darkTheme(p) : _lightTheme(p),
                    onPinchStart: controller.clearSelection,
                    onFontSize: (size) {
                      _setFont(size);
                      _saveFont();
                    },
                    // Long-press selects; this bar copies it, selects everything, or pastes.
                    overlay: ValueListenableBuilder<bool>(
                      valueListenable: _hasSelection,
                      builder: (context, shown, _) =>
                          shown ? Center(child: _selectionBar(p, s)) : const SizedBox.shrink(),
                    ),
                  ),
                ),
                _KeyBar(
                  ctrl: ctrl,
                  onCtrl: () => setState(() => ctrl = !ctrl),
                  onKey: _key,
                  onText: _text,
                  onHistory: _historySheet,
                  onPaste: () => _paste(s),
                  onZoomOut: () {
                    _setFont(fontSize - 1);
                    _saveFont();
                  },
                  onZoomIn: () {
                    _setFont(fontSize + 1);
                    _saveFont();
                  },
                ),
              ],
            ),
    );
  }

  /// Re-checks the toolbar on selection changes and on output (output can evict the selected lines, or switch
  /// to the alternate screen of vim or less, leaving the selection pointing at another buffer).
  void _refreshSelection() {
    final s = session;
    final range = controller.selection;
    if (range != null && (_pane.currentState?.pinching ?? false)) {
      // A long-press that fired under a pinching finger.
      controller.clearSelection();
      return;
    }
    if (range == null) {
      _selectionBuffer = null;
    } else {
      _selectionBuffer ??= s?.terminal.buffer;
    }
    _hasSelection.value = range != null && s != null && identical(_selectionBuffer, s.terminal.buffer);
  }

  /// Listens to the shown tab's output.
  void _watch(Terminal? terminal) {
    if (identical(terminal, _watched)) return;
    _watched?.removeListener(_refreshSelection);
    _watched = terminal;
    terminal?.addListener(_refreshSelection);
  }

  Future<void> _copy(ShellSession s) async {
    final text = _hasSelection.value ? terminalSelectionText(s.terminal, controller) : '';
    controller.clearSelection();
    if (text.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Nothing selected any more'))));
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('Copied')), duration: const Duration(seconds: 1)));
    }
  }

  void _selectAll(ShellSession s) => selectAllTerminal(s.terminal, controller);

  Future<void> _paste(ShellSession s) async {
    controller.clearSelection();
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) s.terminal.paste(text);
    focus.requestFocus();
  }

  void _setFont(double size) {
    final next = terminalFontFor(size);
    if (next != fontSize) setState(() => fontSize = next);
  }

  void _saveFont() => Appearance.instance.setTerminalFontSize(fontSize);

  Widget _selectionBar(Palette p, ShellSession s) {
    // Semantics so screen readers announce these as buttons, not loose text.
    Widget action(String label, IconData icon, VoidCallback onTap) => MergeSemantics(
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: p.inverse),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(color: p.inverse, fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Material(
      color: p.text,
      elevation: 6,
      borderRadius: BorderRadius.circular(Radii.md),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          action(tr('Copy'), LucideIcons.copy, () => _copy(s)),
          action(tr('Select all'), LucideIcons.textSelect, () => _selectAll(s)),
          action(tr('Paste'), LucideIcons.clipboardPaste, () => _paste(s)),
          IconButton(
            tooltip: tr('Close'),
                  onPressed: controller.clearSelection,
            icon: Icon(LucideIcons.x, size: 16, color: p.inverse),
          ),
        ],
      ),
    );
  }

  Widget _tabStrip(Palette p) {
    Widget pill({required Widget child, required bool on, VoidCallback? onTap, VoidCallback? onLongPress}) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: on ? p.text : p.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.lg),
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox(height: 32, child: child),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            controller: tabScroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            children: [
              for (var i = 0; i < sessions.length; i++)
                Builder(
                  builder: (context) {
                    final s = sessions[i];
                    final on = s == session;
                    final fg = on ? p.inverse : (s.exited ? p.faint : p.text);
                    return pill(
                      on: on,
                      onTap: () => _select(i),
                      onLongPress: () => _rename(i),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 12),
                          Icon(s.linux ? LucideIcons.box : LucideIcons.squareTerminal, size: 14, color: fg),
                          const SizedBox(width: 6),
                          Text(
                            s.title,
                            style: TextStyle(
                              fontFamily: mono,
                              fontSize: 12.5,
                              color: fg,
                              decoration: s.exited ? TextDecoration.lineThrough : null,
                            ),
                          ),
                          // A full-height target, so it is hard to miss and hard to hit by accident.
                          Semantics(
                            button: true,
                            label: tr('Close tab'),
                            child: InkResponse(
                              radius: 18,
                              onTap: () => _confirmClose(i),
                              child: SizedBox(
                                width: 34,
                                height: 32,
                                child: Icon(LucideIcons.x, size: 14, color: on ? p.inverse : p.muted),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              PopupMenuButton<String>(
                tooltip: tr('New tab'),
                position: PopupMenuPosition.under,
                onSelected: (v) => switch (v) {
                  'linux' => _newTab(command: 'box', linux: true),
                  'tests' => _runTests(),
                  _ => _newTab(),
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'android',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(agent.remote.active ? LucideIcons.server : LucideIcons.smartphone, size: 18),
                      title: Text(tr(agent.remote.active ? 'Server shell' : 'Android shell')),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'linux',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(LucideIcons.box, size: 18),
                      title: Text(tr(agent.remote.active ? 'Box shell (the agent\'s box)' : 'Linux shell (box)')),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'tests',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(LucideIcons.flaskConical, size: 18),
                      title: Text(tr('Run tests')),
                    ),
                  ),
                ],
                child: Container(
                  height: 32,
                  width: 40,
                  decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(Radii.lg)),
                  alignment: Alignment.center,
                  child: starting
                      ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(LucideIcons.plus, size: 16, color: p.text),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: p.border),
      ],
    );
  }

  static TerminalTheme _darkTheme(Palette p) => TerminalTheme(
    cursor: p.text,
    selection: const Color(0x553D7BFF),
    foreground: p.text,
    background: p.bg,
    black: const Color(0xFF1C1C1F),
    red: const Color(0xFFFF7B72),
    green: const Color(0xFF7EE787),
    yellow: const Color(0xFFE3B341),
    blue: const Color(0xFF79C0FF),
    magenta: const Color(0xFFD2A8FF),
    cyan: const Color(0xFF56D4DD),
    white: const Color(0xFFC9D1D9),
    brightBlack: const Color(0xFF6E7681),
    brightRed: const Color(0xFFFFA198),
    brightGreen: const Color(0xFF56D364),
    brightYellow: const Color(0xFFF2CC60),
    brightBlue: const Color(0xFFA5D6FF),
    brightMagenta: const Color(0xFFE2C5FF),
    brightCyan: const Color(0xFFB3F0FF),
    brightWhite: const Color(0xFFFFFFFF),
    searchHitBackground: const Color(0xFFE3B341),
    searchHitBackgroundCurrent: const Color(0xFF7EE787),
    searchHitForeground: const Color(0xFF0B0B0C),
  );

  static TerminalTheme _lightTheme(Palette p) => TerminalTheme(
    cursor: p.text,
    selection: const Color(0x333D7BFF),
    foreground: p.text,
    background: p.bg,
    black: const Color(0xFF24292F),
    red: const Color(0xFFCF222E),
    green: const Color(0xFF116329),
    yellow: const Color(0xFF9A6700),
    blue: const Color(0xFF0550AE),
    magenta: const Color(0xFF8250DF),
    cyan: const Color(0xFF1B7C83),
    white: const Color(0xFF6E7781),
    brightBlack: const Color(0xFF57606A),
    brightRed: const Color(0xFFA40E26),
    brightGreen: const Color(0xFF1A7F37),
    brightYellow: const Color(0xFF633C01),
    brightBlue: const Color(0xFF218BFF),
    brightMagenta: const Color(0xFFA475F9),
    brightCyan: const Color(0xFF3192AA),
    brightWhite: const Color(0xFF8C959F),
    searchHitBackground: const Color(0xFFFFDF5D),
    searchHitBackgroundCurrent: const Color(0xFF2DA44E),
    searchHitForeground: const Color(0xFF0B0B0C),
  );
}

/// The keys a phone keyboard lacks.
class _KeyBar extends StatelessWidget {
  const _KeyBar({
    required this.ctrl,
    required this.onCtrl,
    required this.onKey,
    required this.onText,
    required this.onPaste,
    required this.onHistory,
    required this.onZoomOut,
    required this.onZoomIn,
  });
  final bool ctrl;
  final VoidCallback onCtrl;
  final void Function(TerminalKey) onKey;
  final void Function(String) onText;
  final VoidCallback onPaste;
  final VoidCallback onHistory;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget key(String label, VoidCallback onTap, {bool active = false, IconData? icon}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: active ? p.text : p.raised,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Container(
            constraints: const BoxConstraints(minWidth: 40),
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: icon != null
                ? Icon(icon, size: 16, color: active ? p.inverse : p.text)
                : Text(
                    label,
                    style: TextStyle(fontFamily: mono, fontSize: 12.5, color: active ? p.inverse : p.text),
                  ),
          ),
        ),
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(top: BorderSide(color: p.border)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              key('A−', onZoomOut),
              key('A+', onZoomIn),
              key('esc', () => onKey(TerminalKey.escape)),
              key('tab', () => onKey(TerminalKey.tab)),
              key('ctrl', onCtrl, active: ctrl),
              key('', () => onKey(TerminalKey.arrowUp), icon: LucideIcons.chevronUp),
              key('', () => onKey(TerminalKey.arrowDown), icon: LucideIcons.chevronDown),
              key('', () => onKey(TerminalKey.arrowLeft), icon: LucideIcons.chevronLeft),
              key('', () => onKey(TerminalKey.arrowRight), icon: LucideIcons.chevronRight),
              for (final c in ['/', '-', '|', '~', r'$', '*', '&', '>', '"', "'"]) key(c, () => onText(c)),
              key('', onPaste, icon: LucideIcons.clipboardPaste),
              key('', onHistory, icon: LucideIcons.history),
            ],
          ),
        ),
      ),
    );
  }
}

/// A server tab whose connection dropped: its shell is still running on the server, one tap away.
class ServerTabLostBar extends StatelessWidget {
  const ServerTabLostBar({super.key, required this.onReconnect});

  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final message = Row(
      children: [
        Icon(LucideIcons.unplug, size: 16, color: p.warning),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            tr('Connection lost. The shell keeps running on the server.'),
            style: TextStyle(fontSize: 12.5, color: p.text),
          ),
        ),
      ],
    );
    final button = TextButton(onPressed: onReconnect, child: Text(tr('Reconnect')));
    return Material(
      color: p.warning.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        // On a narrow phone the button goes under the message rather than squeezing it into a column of words.
        child: LayoutBuilder(
          builder: (context, box) => box.maxWidth < 340
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Padding(padding: const EdgeInsets.only(top: 4, right: 8), child: message),
                    button,
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: message),
                    button,
                  ],
                ),
        ),
      ),
    );
  }
}
