import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

/// Opens PDF inside the app — works reliably on iOS simulator and devices.
class PdfPreviewService {
  static Future<void> show({
    required BuildContext context,
    required Uint8List bytes,
    required String filename,
  }) async {
    if (!context.mounted) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: Text(
              filename,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: PdfPreview(
            canChangeOrientation: false,
            canChangePageFormat: false,
            allowSharing: true,
            allowPrinting: true,
            pdfFileName: filename,
            build: (_) async => bytes,
          ),
        ),
      ),
    );
  }

  /// Directly invokes the native OS print dialog without showing the preview screen.
  static Future<void> printDirectly({
    required Uint8List bytes,
    required String filename,
  }) async {
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: filename,
    );
  }
}
