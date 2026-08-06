import 'package:pdf/widgets.dart' as pw;

/// Seller / company details shown on generated document PDFs.
class CompanyInfo {
  // static const String name = 'Allso Beauty Lanka Pvt. Ltd.';
  // static const String addressLine1 = 'No 1113 Maradana Road';
  // static const String addressLine2 = 'Borella Colombo 08';
  // static const String phone = '0787678767 / 0785758575';
  // static const String email = 'info@allso.lk';

  static const String name = 'Mitahara Private Limited';
  static const String addressLine1 = 'No:387/1/C,Borellla Road';
  static const String addressLine2 = 'Kottawa';
  static const String phone = '0719920824 / 0719920824';
  static const String email = 'mitaharapvtltd@gmail.com';
  static const String registrationNumber = 'PV 00273423';

  /// Left-side company block used in PDF headers.
  static pw.Widget pdfHeaderBlock() {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          name,
          style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 4),
        pw.Text(addressLine1, style: const pw.TextStyle(fontSize: 10)),
        pw.Text(addressLine2, style: const pw.TextStyle(fontSize: 10)),
        pw.Text('Tel :- $phone', style: const pw.TextStyle(fontSize: 10)),
        pw.Text('Email : $email', style: const pw.TextStyle(fontSize: 10)),
        pw.Text('Reg No : $registrationNumber', style: const pw.TextStyle(fontSize: 10)),
      ],
    );
  }
}
