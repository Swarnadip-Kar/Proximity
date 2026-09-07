// Full-screen filterable system-log terminal. Replaces every inline
// Show-log toggle: records screens now carry a Log affordance (terminal
// icon) that pushes here instead of embedding a collapsible log.
//
// Design: mirrors the 500-entry BleLog ring buffer (never grows unbounded);
// bursty entries coalesce through a 200ms flush timer (≤5 setStates/s);
// rows are plain monospace Text (500 SelectableText regions cost real
// frames under beacon load — adb logcat remains the grep/copy path);
// autoscroll jumps once per flush and only while pinned near the bottom.
// Filter chips narrow by tag; no entrance animation (a terminal must never
// replay motion), so this screen is reduced-motion safe by construction.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:proximity_ble/ble.dart';

import '../../design/app_theme.dart';
import '../../design/tokens.dart';
import '../../main.dart';

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  static const _cap = 500;
  static const _flushEvery = ProxDurations.logFlush;
  static const _tags = ProxLogTags.all;

  final List<BleLogEntry> _entries = [];
  final List<BleLogEntry> _pending = [];
  StreamSubscription<BleLogEntry>? _sub;
  Timer? _flush;
  final ScrollController _scroll = ScrollController();

  /// True while the user is pinned near the bottom (autoscroll engaged).
  var _stick = true;

  /// Empty = show all tags.
  final Set<String> _only = {};

  @override
  void initState() {
    super.initState();
    final history = BleLog.history;
    _entries.addAll(
        history.length > _cap ? history.sublist(history.length - _cap) : history);
    _sub = BleLog.stream.listen((e) {
      if (!mounted) return;
      _pending.add(e);
      _flush ??= Timer(_flushEvery, _applyPending);
    });
  }

  void _applyPending() {
    _flush = null;
    if (!mounted || _pending.isEmpty) return;
    setState(() {
      _entries.addAll(_pending);
      _pending.clear();
      if (_entries.length > _cap) {
        _entries.removeRange(0, _entries.length - _cap);
      }
    });
    if (_stick) _scrollToEnd();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _flush?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    Future.microtask(() {
      if (!mounted || !_scroll.hasClients) return;
      try {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      } catch (_) {}
    });
  }

  List<BleLogEntry> get _visible => _only.isEmpty
      ? _entries
      : _entries.where((e) => _only.contains(e.tag)).toList();

  Color _colorFor(String tag) => ProxLogColors.of(tag);

  void _toggleTag(String tag) {
    setState(() {
      if (_only.contains(tag)) {
        _only.remove(tag);
      } else {
        _only.add(tag);
      }
    });
  }

  void _clear() {
    BleLog.clear();
    _pending.clear();
    setState(_entries.clear);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return AdaptiveScaffold(
      title: 'System log',
      actions: [
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Clear',
          onPressed: _clear,
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: ProxSpacing.xs),
                  child: FilterChip(
                    label: const Text('All'),
                    selected: _only.isEmpty,
                    onSelected: (_) => setState(_only.clear),
                  ),
                ),
                for (final tag in _tags)
                  Padding(
                    padding: const EdgeInsets.only(right: ProxSpacing.xs),
                    child: FilterChip(
                      label: Text(tag),
                      selected: _only.contains(tag),
                      onSelected: (_) => _toggleTag(tag),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '${visible.length} of ${_entries.length} events'
              '${_only.isEmpty ? '' : ' · ${_only.join(', ')}'}',
              style: proxTabular(
                  context, Theme.of(context).textTheme.bodySmall),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(ProxRadii.terminal),
                  border: Border.all(color: Colors.grey.shade700),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade900,
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(10)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.terminal,
                              size: 14, color: Colors.white70),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text('system log',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 12),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: visible.isEmpty
                          ? const Center(
                              child: Text(
                                'No events yet — start a window / join a class.',
                                style: TextStyle(
                                    color: Colors.white38,
                                    fontFamily: 'monospace',
                                    fontSize: 12),
                              ),
                            )
                          : NotificationListener<ScrollNotification>(
                              onNotification: (n) {
                                if (n is ScrollUpdateNotification &&
                                    n.metrics.maxScrollExtent > 0) {
                                  _stick =
                                      n.metrics.maxScrollExtent -
                                              n.metrics.pixels <
                                          100;
                                }
                                return false;
                              },
                              child: ListView.builder(
                                controller: _scroll,
                                padding: const EdgeInsets.all(8),
                                itemCount: visible.length,
                                addAutomaticKeepAlives: false,
                                itemBuilder: (ctx, i) {
                                  final e = visible[i];
                                  return Text(
                                    e.line,
                                    style: TextStyle(
                                      color: _colorFor(e.tag),
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      height: 1.35,
                                    ),
                                  );
                                },
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
