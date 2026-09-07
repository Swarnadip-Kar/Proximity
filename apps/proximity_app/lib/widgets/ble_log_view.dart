// Toggleable terminal-style system log view.
//
// Shows live BLE/mesh/security/network events plus the foundation-track
// NAV/SYNC/FACE/STATE tags (navigation, sync/queue, face decision points,
// state recompute reasons):
//   BLE msg received — forwarding to mesh — signing token — token sent —
//   waiting for ack — ack received, plus scan/advertise/relay diagnostics.
// The same widget is embedded in the student attendance/scanning screens
// and the professor scanning page; visibility is toggled per screen.
// Tag colors come from [ProxLogColors] (single source with the
// full-screen debug log).
//
// Performance design (this is a debugging tool on hot screens — BLE +
// camera + networking are already active):
// - bursty entries are COALESCED: a 200ms flush timer applies pending
//   rows at most 5×/s instead of one setState per packet;
// - the view mirrors the 500-entry ring buffer (never grows unbounded);
// - rows are plain Text (monospace): 500 SelectableText regions cost real
//   frames under beacon load; the full stream also mirrors to adb logcat
//   for grepping, so on-screen selection is not the copy path;
// - autoscroll jumps once per flush, and only while the user is already
//   pinned near the bottom (reading history never yanks).
// The toggle itself fades/slides (small, standard) — the only motion here.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:proximity_ble/ble.dart';

import '../design/tokens.dart';

/// Terminal window. Owns its subscription; parent toggles via [visible].
class BleLogView extends StatefulWidget {
  final bool visible;
  final VoidCallback? onToggle;
  final double height;
  const BleLogView({
    super.key,
    required this.visible,
    this.onToggle,
    this.height = 180,
  });

  @override
  State<BleLogView> createState() => _BleLogViewState();
}

class _BleLogViewState extends State<BleLogView> {
  static const _cap = 500;
  final List<BleLogEntry> _entries = [];
  final List<BleLogEntry> _pending = [];
  StreamSubscription<BleLogEntry>? _sub;
  Timer? _flush;
  final ScrollController _scroll = ScrollController();

  /// True while the user is pinned near the bottom (autoscroll engaged).
  var _stick = true;

  @override
  void initState() {
    super.initState();
    final history = BleLog.history;
    _entries.addAll(
        history.length > _cap ? history.sublist(history.length - _cap) : history);
    _sub = BleLog.stream.listen((e) {
      if (!mounted) return;
      _pending.add(e);
      _flush ??= Timer(ProxDurations.logFlush, _applyPending);
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

  Color _colorFor(String tag) => ProxLogColors.of(tag);

  @override
  Widget build(BuildContext context) {
    final duration = ProxMotion.effective(context, ProxDurations.small);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton.icon(
          icon: Icon(
              widget.visible ? Icons.terminal : Icons.terminal_outlined,
              size: 18),
          label: Text(widget.visible ? 'Hide system log' : 'Show system log'),
          onPressed: widget.onToggle,
        ),
        AnimatedSwitcher(
          duration: duration,
          switchInCurve: ProxCurves.standard,
          switchOutCurve: ProxCurves.standard,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -0.08),
                end: Offset.zero,
              ).animate(anim),
              child: SizeTransition(
                sizeFactor: anim,
                alignment: Alignment.topCenter,
                child: child,
              ),
            ),
          ),
          child: widget.visible
              ? Container(
                  key: const ValueKey<String>('log-open'),
                  height: widget.height,
                  margin: const EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius:
                        BorderRadius.circular(ProxRadii.terminal),
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
                        child: Row(
                          children: [
                            const Icon(Icons.terminal,
                                size: 14, color: Colors.white70),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: Text('system log',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 12),
                                  overflow: TextOverflow.ellipsis),
                            ),
                            Text('${_entries.length}',
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 11)),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 16, color: Colors.white70),
                              tooltip: 'Clear',
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                BleLog.clear();
                                _pending.clear();
                                setState(_entries.clear);
                              },
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: _entries.isEmpty
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
                                  itemCount: _entries.length,
                                  addAutomaticKeepAlives: false,
                                  itemBuilder: (ctx, i) {
                                    final e = _entries[i];
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
                )
              : const SizedBox.shrink(key: ValueKey<String>('log-closed')),
        ),
      ],
    );
  }
}
