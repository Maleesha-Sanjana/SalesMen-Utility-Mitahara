import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Cached PDF fonts — load once at startup, reuse for every PDF.
class PdfFonts {
  static pw.ThemeData? _cachedTheme;
  static Future<pw.ThemeData>? _inflight;

  /// Call on app start so the first "Generate PDF" tap is instant.
  static Future<void> preload() => documentTheme().then((_) {});

  static Future<pw.ThemeData> documentTheme() {
    if (_cachedTheme != null) {
      return Future.value(_cachedTheme!);
    }
    return _inflight ??= _loadTheme().then((theme) {
      _cachedTheme = theme;
      return theme;
    });
  }

  static Future<pw.ThemeData> _loadTheme() async {
    final bundled = await _tryBundledTheme();
    if (bundled != null) return bundled;

    final results = await Future.wait([
      PdfGoogleFonts.notoSansRegular(),
      PdfGoogleFonts.notoSansBold(),
    ]);
    final base = results[0];
    final bold = results[1];

    pw.Font? sinhala;
    try {
      sinhala = await PdfGoogleFonts.notoSansSinhalaRegular().timeout(
        const Duration(seconds: 2),
      );
    } catch (_) {}

    return pw.ThemeData.withFont(
      base: base,
      bold: bold,
      fontFallback: sinhala == null ? const [] : [sinhala],
    );
  }

  static Future<pw.ThemeData?> _tryBundledTheme() async {
    try {
      final regularData =
          await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
      final boldData = await rootBundle.load('assets/fonts/NotoSans-Bold.ttf');
      final base = pw.Font.ttf(regularData);
      final bold = pw.Font.ttf(boldData);
      final fallbacks = <pw.Font>[];
      try {
        final sinhalaData = await rootBundle.load(
          'assets/fonts/NotoSansSinhala-Regular.ttf',
        );
        fallbacks.add(pw.Font.ttf(sinhalaData));
      } catch (_) {}
      return pw.ThemeData.withFont(
        base: base,
        bold: bold,
        fontFallback: fallbacks,
      );
    } catch (_) {
      return null;
    }
  }
}
