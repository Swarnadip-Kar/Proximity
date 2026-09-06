// Single-field professor IP entry: one dotted-quad box (digits + dots) +
// port. Stray/double dots are ignored while parsing, so pasted or
// auto-corrected input such as `192..168.43.1` still resolves. Emits a
// validated 'host:port' or null while incomplete/invalid.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class IpJoinField extends StatefulWidget {
  final String initial;
  final ValueChanged<String?> onChanged;
  const IpJoinField(
      {super.key, this.initial = '', required this.onChanged});

  @override
  State<IpJoinField> createState() => _IpJoinFieldState();
}

class _IpJoinFieldState extends State<IpJoinField> {
  late final TextEditingController _ip;
  late final TextEditingController _port;

  @override
  void initState() {
    super.initState();
    _ip = TextEditingController();
    _port = TextEditingController(text: '8443');
    _applyInitial(widget.initial);
  }

  @override
  void didUpdateWidget(IpJoinField old) {
    super.didUpdateWidget(old);
    if (old.initial != widget.initial) _applyInitial(widget.initial);
  }

  void _applyInitial(String v) {
    final hp = _splitHostPort(v);
    if (hp == null) return;
    _ip.text = hp.$1;
    if (hp.$2.isNotEmpty) _port.text = hp.$2;
    _notify();
  }

  /// Returns (host, port) or null when unparseable.
  static (String, String)? _splitHostPort(String v) {
    final s = v.trim();
    if (s.isEmpty) return null;
    var host = s;
    var port = '';
    final colon = s.lastIndexOf(':');
    if (colon >= 0) {
      host = s.substring(0, colon).trim();
      port = s.substring(colon + 1).trim();
    }
    return (host, port);
  }

  /// Normalizes one dotted quad. Empty segments are ignored, so extra dots
  /// never invalidate an otherwise complete address.
  static String? normalizeIp(String raw) {
    final parts = raw
        .trim()
        .split('.')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length != 4) return null;
    final out = <String>[];
    for (final p in parts) {
      if (!RegExp(r'^\d{1,3}$').hasMatch(p)) return null;
      final n = int.parse(p);
      if (n < 0 || n > 255) return null;
      out.add(n.toString());
    }
    return out.join('.');
  }

  void _notify() {
    final host = normalizeIp(_ip.text);
    final port =
        int.tryParse(_port.text.trim().isEmpty ? '8443' : _port.text.trim());
    if (host != null && port != null && port > 0 && port <= 65535) {
      widget.onChanged('$host:$port');
    } else {
      widget.onChanged(null);
    }
  }

  @override
  void dispose() {
    _ip.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Professor IP'),
        const SizedBox(height: 6),
        TextField(
          key: const ValueKey('ipfield'),
          controller: _ip,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.next,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            LengthLimitingTextInputFormatter(15),
          ],
          decoration: const InputDecoration(
            hintText: '192.168.43.1',
            counterText: '',
          ),
          onChanged: (_) => _notify(),
          onSubmitted: (_) => FocusScope.of(context).nextFocus(),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('Port'),
            const SizedBox(width: 8),
            SizedBox(
              width: 96,
              child: TextField(
                key: const ValueKey('ipport'),
                controller: _port,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                textInputAction: TextInputAction.done,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(5),
                ],
                decoration: const InputDecoration(
                  hintText: '8443',
                  counterText: '',
                ),
                onChanged: (_) => _notify(),
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text('Shown by the professor in class.',
            style: TextStyle(fontSize: 12)),
      ],
    );
  }
}
