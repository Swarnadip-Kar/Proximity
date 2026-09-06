// Toggleable terminal-style system log view.
//
// Shows live BLE/mesh/security/network events:
//   BLE msg received — forwarding to mesh — signing token — token sent —
//   waiting for ack — ack received, plus scan/advertise/relay diagnostics.
// The same widget is embedded in the student attendance/scanning screens
// and the professor scanning page; visibility is toggled per screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:proximity_ble/ble.dart';

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
  final List<BleLogEntry> _entries = [];
  StreamSubscription<BleLogEntry>? _sub;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _entries.addAll(BleLog.history);
    _sub = BleLog.stream.listen((e) {
      if (!mounted) return;
      setState(() => _entries.add(e));
      _scrollToEnd();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
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

  Color _colorFor(String tag) {
    return switch (tag) {
      'BLE' => const Color(0xFF4ADE80),
      'MESH' => const Color(0xFF60A5FA),
      'LAN' => const Color(0xFFF472B6),
      'SEC' => const Color(0xFFFBBF24),
      'NET' => const Color(0xFF22D3EE),
      _ => const Color(0xFFE5E7EB),
    };
  }

  @override
  Widget build(BuildContext context) {
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
        if (widget.visible)
          Container(
            height: widget.height,
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(8)),
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
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(8),
                          itemCount: _entries.length,
                          itemBuilder: (ctx, i) {
                            final e = _entries[i];
                            return SelectableText(
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
              ],
            ),
          ),
      ],
    );
  }
}
