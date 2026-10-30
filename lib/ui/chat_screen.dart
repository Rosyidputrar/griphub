import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/drafts.dart';
import '../agent/models.dart';
import '../agent/features.dart';
import 'i18n.dart';
import 'chat_extras.dart';
import 'deploy_sheet.dart';
import 'errors.dart';
import 'message_menu.dart';
import 'message_views.dart';

import 'package:simple_icons/simple_icons.dart';

import 'repos_screen.dart';
import 'kit.dart';
import 'live_clock.dart';
import 'illustration.dart';
import 'mesh.dart';
import 'model_sheet.dart';
import 'tasks_screen.dart';
import 'terminal_screen.dart';
import 'server_screen.dart';
import 'settings_screen.dart';
import 'folder_picker.dart';
import 'subagent_card.dart';
import 'theme.dart';
import 'transfer_dialog.dart';
import 'todo_views.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.agent,
    this.initialPrompt,
    this.initialAttachments = const [],
    this.listenOnOpen = false,
  });
  final AgentController agent;

  /// Pre-filled into the composer (quick starts, shares), for the user to finish.
  final String? initialPrompt;
  final List<Attachment> initialAttachments;

  /// Start voice input right away (the widget's Voice button).
  final bool listenOnOpen;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final scroll = ScrollController();
  final input = TextEditingController();
  final focus = FocusNode();
  bool followBottom = true;

  /// The user's finger is on the list (or it is still flinging from it);
  /// auto-follow must not fight them.
  bool dragging = false;
  int lastCount = 0;
  final attachments = <Attachment>[];
  List<SlashCommand>? slash;

  /// The @ list: files matching what is typed after the @ at the cursor, and the query they answer.
  List<String> mentionFiles = const [];
  String? mentionQuery;
  Timer? _mentionTimer;
  int _mentionAsk = 0;

  /// The chat whose draft the input holds.
  String? draftChat;

  /// The clipboard holds a picture: the field's menu offers "Paste image". Checked when the field gains focus and when
  /// the app comes back (the user copied it in another app).
  bool _clipboardImage = false;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: _checkClipboard);

  AgentController get agent => widget.agent;

  /// "/par" while typing a command name; null otherwise.
  String? get _slashQuery {
    final t = input.text;
    if (!t.startsWith('/') || t.contains(' ') || t.contains('\n')) return null;
    return t.substring(1);
  }

  @override
  void initState() {
    super.initState();
    _lifecycle;
    focus.addListener(() {
      if (focus.hasFocus) _checkClipboard();
    });
    agent.addListener(_onAgentChanged);
    draftChat = agent.sessionId;
    final prompt = widget.initialPrompt ?? Drafts.instance.get(draftChat);
    if (prompt.isNotEmpty) {
      input.text = prompt;
      input.selection = TextSelection.collapsed(offset: prompt.length);
      WidgetsBinding.instance.addPostFrameCallback((_) => focus.requestFocus());
    }
    scroll.addListener(() {
      if (!scroll.hasClients || dragging) return;
      if (_atBottom != followBottom) setState(() => followBottom = _atBottom);
    });
    input.addListener(() {
      Drafts.instance.set(draftChat, input.text);
      if (_slashQuery != null && slash == null) _loadSlash();
      _findMention();
      setState(() {});
    });
    if (widget.initialAttachments.isNotEmpty) {
      attachments.addAll(widget.initialAttachments);
      _saveFiles();
    } else {
      attachments.addAll(_draftFiles());
    }
    if (widget.listenOnOpen) WidgetsBinding.instance.addPostFrameCallback((_) => _voice());
    // History may have loaded before this screen existed.
    lastCount = agent.entries.length;
    _jumpToBottom();
  }

  @override
  void dispose() {
    agent.removeListener(_onAgentChanged);
    _mentionTimer?.cancel();
    _lifecycle.dispose();
    Drafts.instance.flush();
    scroll.dispose();
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  bool get _atBottom => scroll.position.pixels >= scroll.position.maxScrollExtent - 80;

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      dragging = true;
      if (followBottom) setState(() => followBottom = false);
    } else if (n is ScrollEndNotification && dragging) {
      dragging = false;
      // Landing back at the bottom re-arms following.
      if (scroll.hasClients && _atBottom != followBottom) setState(() => followBottom = _atBottom);
    }
    return false;
  }

  void _onAgentChanged() {
    // Another chat opened under this screen (new chat, fork, the open one deleted): bring its draft along.
    if (agent.sessionId != draftChat) {
      draftChat = agent.sessionId;
      final draft = Drafts.instance.get(draftChat);
      input.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
      setState(() {
        attachments
          ..clear()
          ..addAll(_draftFiles());
      });
    }
    final grew = agent.entries.length != lastCount;
    lastCount = agent.entries.length;
    if (followBottom || grew && agent.entries.lastOrNull is UserEntry) _jumpToBottom();
  }

  /// The open chat's saved attachments, still on disk.
  List<Attachment> _draftFiles() => [
    for (final f in Drafts.instance.files(draftChat)) Attachment(f.path, f.name, mime: f.mime),
  ];

  /// Keeps the attachments with the draft (copied into app storage, so they survive the picker's cache).
  void _saveFiles() {
    Drafts.instance.setFiles(draftChat, [for (final a in attachments) (path: a.path, name: a.name, mime: a.mime)]);
  }

  void _jumpToBottom({bool animate = false, int passes = 4}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scroll.hasClients || dragging) return;
      final target = scroll.position.maxScrollExtent;
      if (animate) {
        scroll.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        return;
      }
      scroll.jumpTo(target);
      // A lazy list only estimates its extent until the tail is laid out;
      // settle again next frame if landing there revealed more.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (passes > 1 && scroll.hasClients && scroll.position.maxScrollExtent > target + 1) {
          _jumpToBottom(passes: passes - 1);
        }
      });
    });
  }

  ({int start, String query})? get _mention =>
      input.selection.isCollapsed ? mentionAt(input.text, input.selection.baseOffset) : null;

  /// Asks the host for files matching the @ being typed, a moment after the typing stops; an answer for an older query
  /// is dropped. No @ at the cursor (or no project): no list.
  void _findMention() {
    final m = _mention;
    if (m == null) {
      _mentionTimer?.cancel();
      mentionQuery = null;
      mentionFiles = const [];
      return;
    }
    if (m.query == mentionQuery) return;
    mentionQuery = m.query;
    _mentionTimer?.cancel();
    _mentionTimer = Timer(const Duration(milliseconds: 120), () async {
      final ask = ++_mentionAsk;
      List<String> files;
      try {
        files = await agent.features.findFiles(m.query);
      } catch (_) {
        files = const [];
      }
      if (mounted && ask == _mentionAsk && mentionQuery == m.query) setState(() => mentionFiles = files);
    });
  }

  void _pickMention(String path) {
    final m = _mention;
    if (m == null) return;
    final r = insertMention(input.text, m.start, input.selection.baseOffset, path);
    input.value = TextEditingValue(text: r.text, selection: TextSelection.collapsed(offset: r.cursor));
    focus.requestFocus();
  }

  Future<void> _loadSlash() async {
    slash = const [];
    try {
      final list = await agent.features.slashCommands();
      if (mounted) setState(() => slash = list);
    } catch (_) {}
  }

  /// A message is on its way to the host: Send shows a spinner and a second tap does nothing, so the same text is
  /// never sent twice.
  bool _sending = false;

  Future<void> _send() async {
    if (_sending) return;
    final text = input.text;
    if (text.trim().isEmpty && attachments.isEmpty) return;
    if (!agent.hasModel) {
      await _connectProvider();
      return;
    }
    setState(() => _sending = true);
    try {
      await _sendNow(text);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendNow(String text) async {
    final files = List<Attachment>.of(attachments);
    // Clear only on success: a refused message (budget, host error) never
    // reaches the transcript, so clearing first would lose it.
    final bool ok;
    if (files.isEmpty) {
      ok = await agent.send(text);
    } else {
      // Files go to the server first when the agent is there; that can take a while, and it can fail (the message
      // and its files then stay where they are, to try again).
      final prompt = await runTransfer(
        context,
        connection: widget.agent.client.connection,
        title: tr('Sending files'),
        show: !agent.fs.isLocal,
        task: (h) => preparePrompt(
          text,
          files,
          agent.cwd,
          agent.fs,
          onProgress: h.onProgress,
          cancel: h.cancel,
          onFile: (l) => h.label = l,
        ),
      );
      if (prompt == null) return;
      // The controller queues the files before the call (the host may echo the
      // message before it returns) and drops them on refusal or cancel.
      ok = await agent.sendWith(prompt.text, images: prompt.images, attachments: prompt.files);
    }
    if (!mounted || !ok) return;
    input.clear();
    setState(() => attachments.clear());
    _saveFiles();
    followBottom = true;
  }

  /// Cancels a waiting follow-up; "Edit" puts its text back in the composer.
  Future<void> _cancelQueued(QueuedPrompt q) async {
    HapticFeedback.selectionClick();
    final text = await agent.cancelQueued(q.id);
    if (text == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Message cancelled')),
        action: SnackBarAction(
          label: tr('Edit'),
          onPressed: () {
            if (input.text.trim().isEmpty) {
              input.text = text;
              input.selection = TextSelection.collapsed(offset: text.length);
            } else {
              _insert('\n$text');
            }
            focus.requestFocus();
          },
        ),
      ),
    );
  }

  /// Long-press on send: hand the task to a background agent instead.
  Future<void> _queue() async {
    final text = input.text.trim();
    if (text.isEmpty) return;
    try {
      await agent.features.enqueue(text);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      return;
    }
    input.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Queued as a background task')),
          action: SnackBarAction(
            label: tr('View'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TasksScreen(agent: agent))),
          ),
        ),
      );
    }
  }

  /// A long paste lands as a "Pasted content" attachment; tapping it offers to put it in the field instead.
  void _pasted(String text) {
    final Attachment a;
    try {
      a = pastedAttachment(text);
    } catch (_) {
      // No temp storage: keep the paste as text rather than losing it.
      _insert(text);
      return;
    }
    setState(() => attachments.add(a));
    _saveFiles();
  }

  Future<void> _checkClipboard() async {
    final has = await agent.client.clipboardHasImage();
    if (mounted && has != _clipboardImage) setState(() => _clipboardImage = has);
  }

  /// "Paste image" from the field's menu: the clipboard's picture becomes an attachment.
  Future<void> _pasteImage() async {
    final image = await agent.client.clipboardImage();
    if (!mounted) return;
    if (image == null) {
      setState(() => _clipboardImage = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('The clipboard has no picture to paste'))));
      return;
    }
    setState(() => attachments.add(Attachment(image['path']!, image['name']!, mime: image['mime'])));
    _saveFiles();
  }

  /// A picture the keyboard pasted (Gboard's clipboard, a screenshot, a sticker): attached, never typed as text.
  void _insertedContent(KeyboardInsertedContent content) {
    final bytes = content.data;
    if (bytes == null || bytes.isEmpty || !content.mimeType.startsWith('image/')) return;
    final Attachment a;
    try {
      a = pastedImageAttachment(bytes, content.mimeType);
    } catch (_) {
      return;
    }
    setState(() => attachments.add(a));
    _saveFiles();
  }

  Future<void> _openPasted(Attachment a) async {
    final String text;
    try {
      text = File(a.path).readAsStringSync();
    } catch (_) {
      return;
    }
    final asText = await showPastedSheet(context, text);
    if (asText != true || !mounted || !attachments.remove(a)) return;
    setState(() {});
    _saveFiles();
    _insert(text);
  }

  /// Puts [text] at the cursor (replacing a selection), as a paste would.
  void _insert(String text) {
    final v = input.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    input.value = TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, text),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
  }

  Future<void> _attach() async {
    final picked = await pickAttachments(context, client: agent.client);
    if (picked.isNotEmpty) {
      setState(() => attachments.addAll(picked));
      _saveFiles();
    }
  }

  Future<void> _voice() async {
    try {
      final heard = await agent.client.listen();
      if (heard == null || heard.trim().isEmpty) return;
      final current = input.text.trim();
      input.text = current.isEmpty ? heard : '$current $heard';
      input.selection = TextSelection.collapsed(offset: input.text.length);
      focus.requestFocus();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('Voice input')}: ${friendlyError(e)}')));
    }
  }

  void _prefill(String text) {
    input.text = text;
    input.selection = TextSelection.collapsed(offset: text.length);
    focus.requestFocus();
  }

  /// Long-press on one of your messages: edit & resend, fork, copy.
  Future<void> _userMenu(BuildContext bubbleContext, UserEntry entry, int userIndex) async {
    final action = await showMessageMenu(
      bubbleContext,
      bubble: UserBubble(entry.text),
      actions: [
        MessageAction('copy', tr('Copy'), LucideIcons.copy),
        MessageAction('select', tr('Select text'), LucideIcons.textCursorInput),
        MessageAction('edit', tr('Edit & resend'), LucideIcons.pencil),
        MessageAction('fork', tr('Fork from here'), LucideIcons.gitFork),
      ],
    );
    if (action == null || !mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: entry.text));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Copied'))));
      return;
    }
    if (action == 'select') {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: SingleChildScrollView(child: SelectableText(entry.text, style: Theme.of(context).textTheme.bodyLarge)),
        ),
      );
      return;
    }
    if (agent.busy) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Wait for the agent to finish first'))));
      return;
    }
    if (_rewinding != null) return;
    setState(() => _rewinding = (entry: entry, label: tr(action == 'edit' ? 'Rewinding…' : 'Forking…')));
    try {
      final points = await agent.features.forkPoints();
      if (userIndex >= points.length) throw tr('This message cannot be edited');
      final entryId = points[userIndex].entryId;
      final text = action == 'edit' ? await agent.editMessage(entryId) : await agent.forkAt(entryId);
      _prefill(text.isEmpty ? entry.text : text);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _rewinding = null);
    }
  }

  /// The message an edit or fork is working on, from the tap until the chat has reloaded.
  ({UserEntry entry, String label})? _rewinding;

  Future<void> _connectProvider() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(agent: agent)));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: agent,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          leading: Navigator.of(context).canPop()
              ? IconButton(
                  tooltip: tr('Back'),
                  icon: const Icon(LucideIcons.chevronLeft, size: 24),
                  onPressed: () => Navigator.of(context).pop(),
                )
              : null,
          title: _Title(agent: agent),
          actions: [
            // Phone or server, and whether the server can be reached; only once a server is set up.
            ConnectionChip(agent: agent),
            IconButton(
              tooltip: tr('Terminal'),
              icon: const Icon(LucideIcons.squareTerminal, size: 20),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => TerminalScreen(agent: agent))),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: deployPreparing,
              builder: (context, preparing, _) => IconButton(
                tooltip: tr('Deploy'),
                icon: preparing ? const BusySpinner(size: 18) : const Icon(LucideIcons.rocket, size: 20),
                onPressed: agent.busy || preparing ? null : () => showDeploySheet(context, agent),
              ),
            ),
            IconButton(
              tooltip: tr('Project tools'),
              icon: const Icon(LucideIcons.layoutGrid, size: 20),
              onPressed: () => showProjectTools(context, agent, onPrompt: _prefill),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            ConnectionBanner(agent: agent),
            ServerUpdateBanner(agent: agent),
            Expanded(
              child: Stack(
                children: [
                  agent.entries.isEmpty
                      ? _EmptyState(
                          agent: agent,
                          onConnect: _connectProvider,
                          onPrompt: (prompt) {
                            input.text = prompt;
                            input.selection = TextSelection.collapsed(offset: prompt.length);
                            focus.requestFocus();
                          },
                          onClone: () =>
                              Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReposScreen(agent: agent))),
                        )
                      : NotificationListener<TranscriptGrew>(
                          onNotification: (_) {
                            if (followBottom) _jumpToBottom();
                            return true;
                          },
                          // Content can also shrink or reflow on its own (a live
                          // code panel folding away when a tool call lands);
                          // stay pinned to the bottom through that too.
                          child: NotificationListener<ScrollMetricsNotification>(
                            onNotification: (n) {
                              if (followBottom && !dragging && n.metrics.pixels != n.metrics.maxScrollExtent) {
                                _jumpToBottom();
                              }
                              return false;
                            },
                            child: NotificationListener<ScrollNotification>(
                              onNotification: _onScroll,
                              child: _transcript(),
                            ),
                          ),
                        ),
                  if (!followBottom)
                    Positioned(
                      right: 16,
                      bottom: 12,
                      child: _RoundButton(
                        icon: LucideIcons.arrowDown,
                        label: tr('Scroll to bottom'),
                        onTap: () => _jumpToBottom(animate: true),
                      ),
                    ),
                ],
              ),
            ),
            DevServerBanner(agent: agent),
            ApprovalCards(features: agent.features),
            PlanBar(agent: agent),
            // The agent's todo list for the task at hand (todo_write).
            if (agent.todo != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: TodoProgressBar(agent: agent),
              ),
            if (_slashQuery != null && slash != null)
              SlashMenu(commands: slash!, query: _slashQuery!, onPick: (c) => _prefill('/${c.name} '))
            else if (mentionQuery != null && _mention != null && mentionFiles.isNotEmpty)
              MentionMenu(files: mentionFiles, onPick: _pickMention),
            if (agent.billingNotice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  agent.billingNotice!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.muted),
                ),
              ),
            CrossChatBanner(agent: agent),
            _Composer(
              controller: input,
              focus: focus,
              agent: agent,
              onSend: _send,
              sending: _sending,
              onQueue: _queue,
              onAttach: _attach,
              onPaste: _pasted,
              canPasteImage: _clipboardImage,
              onPasteImage: _pasteImage,
              onInsertedContent: _insertedContent,
              onVoice: _voice,
              attachments: attachments,
              onOpenAttachment: (a) => a.isPasted ? _openPasted(a) : null,
              onRemoveAttachment: (a) {
                setState(() => attachments.remove(a));
                _saveFiles();
              },
              onPickModel: () => showModelSheet(context, agent),
            ),
          ],
        ),
      ),
    );
  }

  /// The line under the transcript while the agent works, or null when something on screen
  /// already shows it: the first-token dots, text typing in, thinking streaming, an approval card.
  String? _activity() {
    if (!agent.busy || agent.features.approvals.isNotEmpty) return null;
    final last = agent.entries.lastOrNull;
    if (last is AssistantEntry) {
      final blocks = last.orderedBlocks;
      if (last.streaming && (blocks.isEmpty || blocks.last.kind != BlockKind.toolCall)) return null;
      for (final b in blocks.reversed) {
        if (b.kind != BlockKind.toolCall) continue;
        final run = agent.tools[b.toolCallId];
        // Arguments still streaming: the tool row says "preparing…" itself.
        if (run == null && last.streaming) return null;
        // A running subagent shows its own progress on its card.
        if (run?.status == ToolStatus.running && b.toolName == 'subagent') return null;
        if (run?.status == ToolStatus.running) {
          return tr('Running {tool}…').replaceAll('{tool}', b.toolName ?? 'tool');
        }
        break;
      }
    }
    // Between steps: a tool finished, the model hasn't answered yet.
    return tr('Thinking…');
  }

  Widget _transcript() {
    final entries = agent.entries;
    final placed = placeSubagents(agent);
    final footers = turnFooters(entries, busy: agent.busy);
    final subs = placed.trailing;
    final retry = agent.endsInError;
    final activity = _activity();
    // While the agent works: what it does, and how long the turn has taken (item under the transcript).
    final status = agent.busy && (activity != null || agent.turnStartedAt != null);
    final queued = agent.queuedPrompts;
    return ListView.builder(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: entries.length + subs.length + (status ? 1 : 0) + queued.length + (retry ? 1 : 0),
      itemBuilder: (context, i) {
        if (i < entries.length) {
          final e = entries[i];
          final child = switch (e) {
            UserEntry() => UserMessageView(
              e,
              onLongPress: _rewinding != null
                  ? null
                  : (bubble) => _userMenu(bubble, e, entries.take(i).whereType<UserEntry>().length),
              fs: agent.fs,
              working: identical(_rewinding?.entry, e) ? _rewinding!.label : null,
            ),
            AssistantEntry() => AssistantMessageView(
              e,
              tools: agent.tools,
              cwd: agent.cwd,
              agent: agent,
              live: agent,
              modelLabel: agent.modelLabel,
              subagentCard: placed.cardFor,
              subagentCost: (id) => switch (agent.subagentStore.all.where((s) => s.toolCallId == id).firstOrNull) {
                final s? => (credits: s.credits),
                null => null,
              },
              footer: footers[i],
            ),
            NoticeEntry() => NoticeView(e),
            JobEntry() => JobNoticeView(e),
            CompactionEntry() => CompactionView(e),
          };
          final gap = i == 0 ? 0.0 : (e is UserEntry ? 28.0 : 14.0);
          return Padding(
            padding: EdgeInsets.only(top: gap),
            child: child,
          );
        }
        final si = i - entries.length;
        if (si < subs.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 14),
            child: SubagentCard(key: ValueKey(subs[si].id), state: subs[si], agent: agent),
          );
        }
        if (status && si == subs.length) {
          final tokens = turnTokensSoFar(entries);
          return Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (activity != null) ...[AgentActivity(label: activity), const SizedBox(height: 8)],
                // The turn's live clock, with the tokens it has used so far.
                LiveClock(
                  label: tr('Working'),
                  startedAt: agent.turnStartedAt,
                  detail: tokens > 0 ? tr('{n} tokens').replaceAll('{n}', localNumber(formatTokens(tokens))) : null,
                ),
              ],
            ),
          );
        }
        // Follow-ups waiting for the current turn to end, oldest first.
        final qi = si - subs.length - (status ? 1 : 0);
        if (qi < queued.length) {
          return Padding(
            padding: EdgeInsets.only(top: qi == 0 ? 28 : 10),
            child: QueuedMessageView(
              key: ValueKey('queued-${queued[qi].id}'),
              prompt: queued[qi],
              onCancel: () => _cancelQueued(queued[qi]),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: _RetryBar(onRetry: agent.retry, onPickModel: () => showModelSheet(context, agent)),
        );
      },
    );
  }
}

/// Shown under a failed turn: try again, or switch model first.
class _RetryBar extends StatelessWidget {
  const _RetryBar({required this.onRetry, required this.onPickModel});
  final VoidCallback onRetry;
  final VoidCallback onPickModel;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.tonalIcon(
          onPressed: onRetry,
          icon: const Icon(LucideIcons.rotateCcw, size: 16),
          label: Text(tr('Try again')),
        ),
        OutlinedButton.icon(
          onPressed: onPickModel,
          icon: const Icon(LucideIcons.sparkles, size: 16),
          label: Text(tr('Switch model')),
        ),
      ],
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final name = agent.sessionName?.trim();
    final firstUser = agent.entries.whereType<UserEntry>().firstOrNull?.text.split('\n').first;
    final title = (name != null && name.isNotEmpty) ? name : (firstUser ?? tr('New chat'));
    // Sessions inside a project folder show which one.
    final project = sessionFolder(agent.cwd, agent.info['workspace'] as String? ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (project != null || agent.model != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (project != null) ...[
                Icon(LucideIcons.folderGit2, size: 12, color: p.accent),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    project,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.muted),
                  ),
                ),
              ] else
                Flexible(
                  child: Text(
                    agent.model!.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: p.faint, fontWeight: FontWeight.w500),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.agent, required this.onConnect, required this.onPrompt, required this.onClone});
  final AgentController agent;
  final VoidCallback onConnect;
  final void Function(String prompt) onPrompt;
  final VoidCallback onClone;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final ready = agent.hasModel;
    final suggestions = [
      // Same names, blurbs and colours as the quick starts on Home.
      (
        LucideIcons.layoutTemplate,
        const Color(0xFFFF7A1A),
        'Build a web app',
        'A site or app, ready to deploy',
        'Build me a polished, mobile-first web app: ',
      ),
      // p.text, not Home's slate: this soft tile tints the icon with its own colour.
      (SimpleIcons.github, p.text, 'Clone a GitHub repo', 'Pick up an existing project', null),
      (
        SimpleIcons.python,
        const Color(0xFF3B82F6),
        'Python in Linux',
        'Scripts in a real Linux container',
        'Set up a Python environment in the Linux container with requests and rich, then write a hello script.',
      ),
      (
        LucideIcons.folderSearch,
        const Color(0xFF14B8A6),
        'Explore workspace',
        'Summarize what is on this device',
        'Look around the workspace and give me a short tour of what is there.',
      ),
    ];
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight - 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // In a pastel tile like the Home cards; on the bare page its white panels look like a pasted box.
              const SizedBox(
                width: 236,
                height: 196,
                child: MeshArt(
                  seed: 'hello',
                  radius: Radii.xl,
                  child: Padding(padding: EdgeInsets.all(12), child: Illustration('ai', height: 172)),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                tr(ready ? 'What should we build?' : 'Connect a model to begin'),
                style: text.displaySmall?.copyWith(fontSize: 26),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                ready
                    ? tr('The agent codes, runs commands, installs packages and deploys, right here on your phone.')
                    : tr('The agent runs on your phone. Sign in to a provider or add an API key to choose its model.'),
                style: text.bodyMedium?.copyWith(color: p.muted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              if (!ready)
                SizedBox(
                  width: 260,
                  child: PrimaryButton(label: tr('Connect a model'), icon: LucideIcons.sparkles, onPressed: onConnect),
                )
              else
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.35,
                  children: [
                    for (final (icon, color, title, blurb, prompt) in suggestions)
                      SurfaceCard(
                        padding: const EdgeInsets.all(14),
                        onTap: prompt == null ? onClone : () => onPrompt(tr(prompt)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            IconTile(icon: icon, color: color, size: 32),
                            // Text from the top, so titles line up across a row whatever the blurb length.
                            const SizedBox(height: 14),
                            Text(tr(title), style: text.titleSmall),
                            const SizedBox(height: 2),
                            Text(tr(blurb), maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                            const Spacer(),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.agent,
    required this.onSend,
    this.sending = false,
    required this.onQueue,
    required this.onAttach,
    required this.onPaste,
    this.canPasteImage = false,
    this.onPasteImage,
    this.onInsertedContent,
    required this.onVoice,
    required this.attachments,
    required this.onOpenAttachment,
    required this.onRemoveAttachment,
    required this.onPickModel,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final AgentController agent;
  final VoidCallback onSend;

  /// The last message is still on its way: Send spins and is off.
  final bool sending;
  final VoidCallback onQueue;
  final VoidCallback onAttach;

  /// Called instead of inserting a long paste (see LongPasteFormatter).
  final void Function(String text) onPaste;

  /// The clipboard holds a picture: the field's menu offers [onPasteImage].
  final bool canPasteImage;
  final VoidCallback? onPasteImage;

  /// A picture the keyboard pasted.
  final void Function(KeyboardInsertedContent content)? onInsertedContent;
  final VoidCallback onVoice;
  final List<Attachment> attachments;
  final void Function(Attachment) onOpenAttachment;
  final void Function(Attachment) onRemoveAttachment;
  final VoidCallback onPickModel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasText = controller.text.trim().isNotEmpty || attachments.isNotEmpty;
    final busy = agent.busy;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: ListenableBuilder(
          listenable: focus,
          builder: (context, child) => AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(Radii.xl),
              border: Border.all(color: focus.hasFocus ? p.accent.withValues(alpha: 0.55) : p.border),
              boxShadow: [
                BoxShadow(
                  color: (focus.hasFocus ? p.accent : Colors.black).withValues(alpha: focus.hasFocus ? 0.18 : 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                  spreadRadius: -8,
                ),
              ],
            ),
            child: child,
          ),
          child: Column(
            children: [
              if (attachments.isNotEmpty)
                AttachmentStrip(items: attachments, onOpen: onOpenAttachment, onRemove: onRemoveAttachment),
              TextField(
                controller: controller,
                focusNode: focus,
                inputFormatters: [LongPasteFormatter(onPaste)],
                contentInsertionConfiguration: onInsertedContent == null
                    ? null
                    : ContentInsertionConfiguration(
                        allowedMimeTypes: pasteImageTypes,
                        onContentInserted: onInsertedContent!,
                      ),
                contextMenuBuilder: (context, editable) => AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: editable.contextMenuAnchors,
                  buttonItems: [
                    ...editable.contextMenuButtonItems,
                    if (canPasteImage && onPasteImage != null)
                      ContextMenuButtonItem(
                        label: tr('Paste image'),
                        onPressed: () {
                          editable.hideToolbar();
                          onPasteImage!();
                        },
                      ),
                  ],
                ),
                minLines: 1,
                maxLines: 8,
                textCapitalization: TextCapitalization.sentences,
                style: Theme.of(context).textTheme.bodyLarge,
                decoration: InputDecoration(
                  hintText: busy ? tr('Queue a follow-up…') : tr('Ask the agent to build, fix or deploy…'),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  // 48 dp tall with one line, like the controls under it.
                  contentPadding: const EdgeInsets.fromLTRB(18, 16, 18, 7),
                ),
              ),
              Padding(
                // Less inset than the look suggests: the controls' touch boxes reach past what they draw.
                padding: const EdgeInsets.fromLTRB(3, 0, 5, 3),
                child: Row(
                  children: [
                    // Each control's 48 dp touch box carries its own margin: no gaps between them.
                    _IconChip(icon: LucideIcons.plus, label: tr('Attach'), onTap: onAttach),
                    // The chips share what the buttons on the right leave; the model chip shrinks first,
                    // and the buttons stay flush right however short the model name is.
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: _Chip(
                              leading: agent.model == null ? null : BrandTile(id: agent.model!.provider, size: 20),
                              label: agent.model?.name ?? tr('Choose model'),
                              icon: LucideIcons.chevronsUpDown,
                              onTap: onPickModel,
                            ),
                          ),
                          if (agent.thinkingLevels.length > 1) ...[
                            const SizedBox(width: 6),
                            _ThinkingChip(agent: agent),
                          ],
                          _IconChip(
                            icon: LucideIcons.listChecks,
                            label: tr(agent.planMode ? 'Plan mode on' : 'Plan mode'),
                            active: agent.planMode,
                            onTap: () => agent.setPlanMode(!agent.planMode),
                          ),
                        ],
                      ),
                    ),
                    // While the agent works, Stop stays reachable; typed text adds Send (queues a follow-up).
                    if (busy)
                      _RoundButton(icon: LucideIcons.square, label: tr('Stop'), filled: !hasText, onTap: agent.abort),
                    if (hasText || sending)
                      _RoundButton(
                        onLongPress: sending ? null : onQueue,
                        icon: LucideIcons.arrowUp,
                        label: tr(sending ? 'Sending…' : 'Send'),
                        filled: true,
                        busy: sending,
                        onTap: sending ? null : onSend,
                      )
                    else if (!busy)
                      _RoundButton(icon: LucideIcons.mic, label: tr('Voice'), filled: false, onTap: onVoice),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A round icon-only chip for composer actions.
class _IconChip extends StatelessWidget {
  const _IconChip({required this.icon, required this.label, required this.onTap, this.active = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: TapTarget(
          onTap: onTap,
          child: Material(
            color: active ? p.accent : p.raised,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox.square(dimension: 34, child: Icon(icon, size: 17, color: active ? p.onAccent : p.text)),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThinkingChip extends StatelessWidget {
  const _ThinkingChip({required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final on = agent.thinkingLevel != 'off';
    return PopupMenuButton<String>(
      tooltip: tr('Thinking level'),
      initialValue: agent.thinkingLevel,
      onSelected: agent.setThinking,
      position: PopupMenuPosition.over,
      elevation: 0,
      itemBuilder: (context) => [
        // "Medium" alone doesn't say what it sets.
        PopupMenuItem(
          enabled: false,
          height: 32,
          child: Text(tr('Thinking level'), style: Theme.of(context).textTheme.labelSmall),
        ),
        for (final level in agent.thinkingLevels)
          PopupMenuItem(value: level, height: 40, child: Text(_levelLabel(level))),
      ],
      child: IgnorePointer(
        child: _Chip(
          leading: Icon(LucideIcons.brain, size: 14, color: on ? context.palette.accent : context.palette.muted),
          label: _levelLabel(agent.thinkingLevel),
          onTap: () {},
        ),
      ),
    );
  }

  static String _levelLabel(String level) => switch (level) {
    'off' => tr('Off'),
    'minimal' => tr('Minimal'),
    'low' => tr('Low'),
    'medium' => tr('Medium'),
    'high' => tr('High'),
    'xhigh' => tr('Max'),
    _ => level,
  };
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap, this.icon, this.leading});
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // The button is the 48 dp box, so a screen reader's focus is that size too.
    return Semantics(
      button: true,
      container: true,
      child: TapTarget(
        onTap: onTap,
        child: Material(
          color: p.raised,
          borderRadius: BorderRadius.circular(Radii.pill),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Radii.pill),
            child: Container(
              height: 34,
              padding: EdgeInsets.fromLTRB(leading == null ? 12 : 6, 0, 10, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 6)],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: p.text),
                    ),
                  ),
                  if (icon != null) ...[const SizedBox(width: 4), Icon(icon, size: 13, color: p.faint)],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.onTap,
    required this.label,
    this.filled = false,
    this.onLongPress,
    this.busy = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool filled;

  /// A spinner in place of the icon (the button's work is on its way).
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onTap != null;
    final active = filled && enabled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: TapTarget(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? p.accent : (filled ? p.raised : p.surface),
            border: filled ? null : Border.all(color: p.border),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: p.accent.withValues(alpha: 0.45),
                      blurRadius: 14,
                      spreadRadius: -4,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              onLongPress: onLongPress,
              child: busy
                  // The button's own label says what it is busy with ("Sending…").
                  ? Center(child: BusySpinner(color: p.muted, semanticsLabel: ''))
                  : Icon(icon, size: 18, color: active ? p.onAccent : (filled ? p.faint : p.text)),
            ),
          ),
        ),
      ),
    );
  }
}
