// Professor export default location: one resolver for every CSV save.
//
// All export saves flow through `saveTextFile` (see file_saver_io.dart /
// file_saver_web.dart), which resolves its destination here: an explicit
// per-device custom directory when one is stored, otherwise the system
// Downloads folder, otherwise the app documents directory. Web builds
// ignore the directory (browser download) and keep working as today.
//
// Platform-neutral on purpose (no dart:io / path_provider import) so the
// account settings UI and unit tests share it on every target; the io
// implementation injects the real path_provider fetchers.
library;

/// SharedPreferences / device-store key for the custom export directory.
/// '' / missing = no custom location (system Downloads default).
const exportDirPrefsKey = 'prox.exportDir.v1';

/// Display string for the setting row: the stored path, or the system
/// default label when none is stored.
String exportDirDisplayName(String? dir) {
  final clean = normalizeExportDir(dir);
  return clean ?? 'Downloads (system default)';
}

/// Normalizes a stored/picked directory. Pure: blank/whitespace-only reads
/// as null (no custom location); anything else is trimmed.
String? normalizeExportDir(String? raw) {
  final v = (raw ?? '').trim();
  return v.isEmpty ? null : v;
}

/// Resolves the directory exports land in. Pure logic over injected
/// fetchers so unit tests cover every branch without plugins:
///
/// 1. a stored custom directory wins verbatim (validated writable at
///    pick time — see `isExportDirWritable`);
/// 2. otherwise the system Downloads folder;
/// 3. otherwise (Downloads unavailable/throws on the platform) the app
///    documents directory — saves never fail for lack of a folder.
Future<String> resolveExportDir({
  String? customDir,
  Future<String?> Function()? getDownloadsPath,
  required Future<String> Function() getDocumentsPath,
}) async {
  final custom = normalizeExportDir(customDir);
  if (custom != null) return custom;
  try {
    final downloads = normalizeExportDir(await getDownloadsPath?.call());
    if (downloads != null) return downloads;
  } catch (_) {
    // Downloads lookup is best-effort (throws on some targets) —
    // fall through to the documents directory below.
  }
  return getDocumentsPath();
}
