import 'dart:io';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() async {
  final pdf = pw.Document();

  pdf.addPage(
    pw.Page(
      build: (pw.Context context) {
        return pw.Center(
          child: pw.Stack(
            children: [
              pw.Positioned(left: -1, top: -1, child: pw.Text('INVOICE', style: pw.TextStyle(fontSize: 40, color: PdfColors.black))),
              pw.Positioned(left: 1, top: -1, child: pw.Text('INVOICE', style: pw.TextStyle(fontSize: 40, color: PdfColors.black))),
              pw.Positioned(left: -1, top: 1, child: pw.Text('INVOICE', style: pw.TextStyle(fontSize: 40, color: PdfColors.black))),
              pw.Positioned(left: 1, top: 1, child: pw.Text('INVOICE', style: pw.TextStyle(fontSize: 40, color: PdfColors.black))),
              pw.Text('INVOICE', style: pw.TextStyle(fontSize: 40, color: PdfColors.white)),
            ],
          ),
        );
      },
    ),
  );

  final file = File('test_outline2.pdf');
  await file.writeAsBytes(await pdf.save());
  print('PDF generated with stack!');
}
