import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'company_info.dart';
import 'pdf_fonts.dart';
import 'pdf_preview_service.dart';

class SalesOrderPdfGenerator {
  static final _money = NumberFormat('#,##0.00');
  static final _date = DateFormat('M/d/yyyy');

  static String numberToWords(double amount) {
    final rupees = amount.toInt();
    final paise = ((amount - rupees) * 100).toInt();

    String convert(int num) {
      if (num == 0) return '';

      final ones = [
        '',
        'One',
        'Two',
        'Three',
        'Four',
        'Five',
        'Six',
        'Seven',
        'Eight',
        'Nine',
      ];
      final teens = [
        'Ten',
        'Eleven',
        'Twelve',
        'Thirteen',
        'Fourteen',
        'Fifteen',
        'Sixteen',
        'Seventeen',
        'Eighteen',
        'Nineteen',
      ];
      final tens = [
        '',
        '',
        'Twenty',
        'Thirty',
        'Forty',
        'Fifty',
        'Sixty',
        'Seventy',
        'Eighty',
        'Ninety',
      ];

      if (num < 10) return ones[num];
      if (num < 20) return teens[num - 10];
      if (num < 100) return '${tens[num ~/ 10]} ${ones[num % 10]}'.trim();
      if (num < 1000) {
        final hundred = num ~/ 100;
        final remainder = num % 100;
        return '${ones[hundred]} Hundred${remainder > 0 ? ' ${convert(remainder)}' : ''}';
      }
      if (num < 100000) {
        final thousand = num ~/ 1000;
        final remainder = num % 1000;
        return '${convert(thousand)} Thousand${remainder > 0 ? ' ${convert(remainder)}' : ''}';
      }
      if (num < 10000000) {
        final lakh = num ~/ 100000;
        final remainder = num % 100000;
        return '${convert(lakh)} Lakh${remainder > 0 ? ' ${convert(remainder)}' : ''}';
      }
      final crore = num ~/ 10000000;
      final remainder = num % 10000000;
      return '${convert(crore)} Crore${remainder > 0 ? ' ${convert(remainder)}' : ''}';
    }

    final rupeesText = convert(rupees);
    final paiseText = paise > 0 ? ' and ${convert(paise)} Cents' : '';
    return '${rupeesText} Rupees$paiseText Only';
  }

  static double _lineDiscountAmount(
    Map<String, dynamic> row,
    double price,
    double qty,
  ) {
    final raw = row['discount']?.toString() ?? '0';
    final numeric =
        double.tryParse(raw.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
    if (numeric <= 0) return 0.0;
    if (raw.contains('%')) return price * qty * (numeric / 100);
    return numeric;
  }

  static String _productCode(Map<String, dynamic> row) {
    final code = row['code']?.toString().trim() ?? '';
    if (code.isNotEmpty) return code.toUpperCase();
    final item = row['item']?.toString() ?? '';
    if (item.contains('•')) {
      return item.split('•').first.trim().toUpperCase();
    }
    return '';
  }

  static String _productName(Map<String, dynamic> row) {
    final name = row['name']?.toString().trim() ?? '';
    if (name.isNotEmpty) return name.toUpperCase();
    final item = row['item']?.toString() ?? '';
    if (item.contains('•')) {
      return item.split('•').skip(1).join('•').trim().toUpperCase();
    }
    return item.toUpperCase();
  }

  static int _creditPeriodDays(Map<String, dynamic> customer) {
    final raw =
        customer['creditPeriod'] ??
        customer['CreditPeriod'] ??
        customer['credit_period'];
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  static String _formatPhone(String phone) {
    return phone.replaceAllMapped(
      RegExp(r'\b(0\d{2})(\d{7})\b'),
      (m) => '${m[1]}-${m[2]}',
    );
  }

  static String _customerContactNumber(Map<String, dynamic> customer) {
    for (final key in ['phone', 'mobile', 'Phone', 'Mobile']) {
      final value = customer[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String _customerSectionLabel(Map<String, dynamic> customer) {
    final name = (customer['name']?.toString() ?? '').trim();
    final contact = _customerContactNumber(customer);

    if (name.isNotEmpty && contact.isNotEmpty) {
      return '${name.toUpperCase()} ($contact)';
    }
    if (name.isNotEmpty) return name.toUpperCase();
    if (contact.isNotEmpty) return contact;
    return '—';
  }

  static String _customerDetailLine(Map<String, dynamic> customer) {
    final code = (customer['code']?.toString() ?? '').trim();
    final address = (customer['address']?.toString() ?? '').trim();
    final parts = <String>[
      if (code.isNotEmpty) code,
      if (address.isNotEmpty) address,
    ];
    return parts.isEmpty ? '—' : parts.join('  |  ');
  }

  static Future<Uint8List> generatePDF({
    required String documentNo,
    required DateTime documentDate,
    required Map<String, dynamic> customer,
    required List<Map<String, dynamic>> rows,
    required double subtotal,
    required double billDiscountAmount,
    required double discountedAmount,
    required double taxAmount,
    required double netAmount,
    required String? remarks,
    required String salesmanName,
    String? poNumber,
    required double Function(Map<String, dynamic>) getPriceFromRow,
    BuildContext? context,
    bool preview = true,
    List<Map<String, dynamic>>? paymentMethods,
  }) async {
    final theme = await PdfFonts.documentTheme();
    final pdf = pw.Document(theme: theme);

    final logoData = await rootBundle.load('assets/allsoLogo.png');
    final logoImage = pw.MemoryImage(logoData.buffer.asUint8List());
    final creditDays = _creditPeriodDays(customer);


    var grossTotal = 0.0;
    var lineDiscountTotal = 0.0;
    final lineRows = <_SalesOrderLine>[];
    for (final row in rows) {
      final qty =
          (row['qty'] as num?)?.toDouble() ??
          (row['quantity'] as num?)?.toDouble() ??
          0.0;
      final price = getPriceFromRow(row);
      final discount = _lineDiscountAmount(row, price, qty);
      final amount = (price * qty) - discount;
      grossTotal += price * qty;
      lineDiscountTotal += discount;
      lineRows.add(
        _SalesOrderLine(
          code: _productCode(row),
          description: _productName(row),
          qty: qty,
          price: price,
          discount: discount,
          amount: amount,
        ),
      );
    }

    if (grossTotal <= 0 && subtotal > 0) grossTotal = subtotal;
    final totalDiscount = lineDiscountTotal + billDiscountAmount;
    final payable = netAmount > 0
        ? netAmount
        : (grossTotal - totalDiscount + taxAmount);

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(64, 32, 36, 32),
        build: (pw.Context context) {
          return [
            _buildHeader(
              logoImage: logoImage,
              documentNo: documentNo,
              documentDate: documentDate,
              poNumber: poNumber,
              creditDays: creditDays,
            ),
            pw.SizedBox(height: 16),
            _buildCustomerBlock(customer),
            pw.SizedBox(height: 14),
            _buildItemsTable(lineRows),
            pw.SizedBox(height: 16),
            _buildTermsAndTotals(
              grossTotal: grossTotal,
              totalDiscount: totalDiscount,
              taxAmount: taxAmount,
              netPayable: payable,
              remarks: remarks,
              paymentMethods: paymentMethods,
            ),
            pw.SizedBox(height: 36),
            _buildSignatures(salesmanName),
          ];
        },
      ),
    );

    final bytes = await pdf.save();
    if (!preview) return bytes;

    if (context != null && context.mounted) {
      await PdfPreviewService.show(
        context: context,
        bytes: bytes,
        filename: 'SalesOrder_$documentNo.pdf',
      );
      return bytes;
    }

    return bytes;
  }

  static pw.Widget _buildHeader({
    required pw.MemoryImage logoImage,
    required String documentNo,
    required DateTime documentDate,
    required String? poNumber,
    required int creditDays,
  }) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Image(logoImage, height: 36, fit: pw.BoxFit.contain, alignment: pw.Alignment.topLeft),
              pw.SizedBox(height: 8),
              pw.Text(
                CompanyInfo.name,
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                ),
                textAlign: pw.TextAlign.left,
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                '${CompanyInfo.addressLine1}, ${CompanyInfo.addressLine2}',
                style: const pw.TextStyle(
                  fontSize: 8.5,
                  color: PdfColors.grey700,
                ),
                textAlign: pw.TextAlign.left,
              ),
              pw.Text(
                'Tel: ${_formatPhone(CompanyInfo.phone)}',
                style: const pw.TextStyle(
                  fontSize: 8.5,
                  color: PdfColors.grey700,
                ),
                textAlign: pw.TextAlign.left,
              ),
              pw.Text(
                'Email: ${CompanyInfo.email}',
                style: const pw.TextStyle(
                  fontSize: 8.5,
                  color: PdfColors.grey700,
                ),
                textAlign: pw.TextAlign.left,
              ),
              pw.Text(
                'Reg No: ${CompanyInfo.registrationNumber}',
                style: const pw.TextStyle(
                  fontSize: 8.5,
                  color: PdfColors.grey700,
                ),
                textAlign: pw.TextAlign.left,
              ),
            ],
          ),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text('SALES ORDER', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, letterSpacing: 0.5, color: PdfColors.black)),
            pw.SizedBox(height: 10),
            _metaRow('Order No:', documentNo),
            _metaRow('Date:', _date.format(documentDate)),
            if (poNumber != null && poNumber.trim().isNotEmpty)
              _metaRow('PO Number:', poNumber.trim()),
          ],
        ),
      ],
    );
  }

  static pw.Widget _metaRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.SizedBox(
            width: 88,
            child: pw.Text(
              label,
              style: pw.TextStyle(
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.grey700,
              ),
              textAlign: pw.TextAlign.right,
            ),
          ),
          pw.SizedBox(width: 6),
          pw.Text(value, style: const pw.TextStyle(fontSize: 8.5)),
        ],
      ),
    );
  }

  static pw.Widget _buildCustomerBlock(Map<String, dynamic> customer) {
    final name = (customer['name']?.toString() ?? '').trim();
    final address = (customer['address']?.toString() ?? '').trim();
    final mobile = _customerContactNumber(customer);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          width: double.infinity,
          color: PdfColors.grey300,
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: pw.Text(
            'CUSTOMER DETAILS',
            style: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
              letterSpacing: 0.4,
            ),
          ),
        ),
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.fromLTRB(8, 8, 8, 6),
          decoration: const pw.BoxDecoration(
            border: pw.Border(
              bottom: pw.BorderSide(color: PdfColors.grey400, width: 0.6),
            ),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (name.isNotEmpty) pw.Text(name, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
              if (address.isNotEmpty) pw.Text(address, style: const pw.TextStyle(fontSize: 9.5)),
              if (mobile.isNotEmpty) pw.Text(mobile, style: const pw.TextStyle(fontSize: 9.5)),
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildItemsTable(List<_SalesOrderLine> lines) {
    final headerStyle = pw.TextStyle(
      fontSize: 7.5,
      fontWeight: pw.FontWeight.bold,
      color: PdfColors.black,
    );
    const cellStyle = pw.TextStyle(fontSize: 7.5);

    pw.Widget headerCell(String text, {pw.TextAlign align = pw.TextAlign.left}) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 6),
        child: pw.Text(text, style: headerStyle, textAlign: align),
      );
    }

    pw.Widget cell(
      String text, {
      pw.TextAlign align = pw.TextAlign.left,
      pw.FontWeight? weight,
    }) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        child: pw.Text(
          text,
          style: weight != null
              ? pw.TextStyle(fontSize: 7.5, fontWeight: weight)
              : cellStyle,
          textAlign: align,
        ),
      );
    }

    return pw.Table(
      columnWidths: {
        0: const pw.FlexColumnWidth(1.1),
        1: const pw.FlexColumnWidth(3.2),
        2: const pw.FlexColumnWidth(0.8),
        3: const pw.FlexColumnWidth(1.2),
        4: const pw.FlexColumnWidth(1.3),
        5: const pw.FlexColumnWidth(1.3),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey100),
          children: [
            headerCell('CODE'),
            headerCell('DESCRIPTION'),
            headerCell('QTY', align: pw.TextAlign.right),
            headerCell('PRICE (LKR)', align: pw.TextAlign.right),
            headerCell('DISCOUNT (LKR)', align: pw.TextAlign.right),
            headerCell('AMOUNT (LKR)', align: pw.TextAlign.right),
          ],
        ),
        ...lines.asMap().entries.map((entry) {
          final line = entry.value;
          return pw.TableRow(
            children: [
              cell(line.code),
              cell(line.description),
              cell(_money.format(line.qty), align: pw.TextAlign.right),
              cell(_money.format(line.price), align: pw.TextAlign.right),
              cell(_money.format(line.discount), align: pw.TextAlign.right),
              cell(
                _money.format(line.amount),
                align: pw.TextAlign.right,
                weight: pw.FontWeight.bold,
              ),
            ],
          );
        }),
      ],
    );
  }

  static Map<String, dynamic> _parseRemarks(
    String? remarks,
    List<Map<String, dynamic>>? paymentMethods,
  ) {
    String paymentTextFromList = '';
    if (paymentMethods != null && paymentMethods.isNotEmpty) {
      paymentTextFromList = paymentMethods.map((p) {
        final mode =
            p['mode'] ?? p['PaymentMode'] ?? p['paymentMode'] ?? 'Payment';
        final amt = (p['amount'] as num?)?.toDouble() ?? 0.0;
        return '$mode: Rs.${_money.format(amt)}';
      }).join(', ');
    }

    if (remarks == null || remarks.trim().isEmpty) {
      return {
        'hasPayment': paymentTextFromList.isNotEmpty,
        'paymentText': paymentTextFromList,
        'noteText': '',
      };
    }

    final text = remarks.trim();
    if (text.contains('Payment Mode:') ||
        text.contains('Payment:') ||
        text.contains('[Payment:')) {
      String paymentPart = '';
      String notePart = '';

      if (text.contains(' | Note: ')) {
        final parts = text.split(' | Note: ');
        paymentPart = parts[0]
            .replaceAll('Payment Mode:', '')
            .replaceAll('Payment:', '')
            .replaceAll('[', '')
            .replaceAll(']', '')
            .trim();
        notePart = parts.length > 1 ? parts[1].trim() : '';
      } else if (text.contains(' | Remark: ')) {
        final parts = text.split(' | Remark: ');
        paymentPart = parts[0]
            .replaceAll('Payment Mode:', '')
            .replaceAll('Payment:', '')
            .replaceAll('[', '')
            .replaceAll(']', '')
            .trim();
        notePart = parts.length > 1 ? parts[1].trim() : '';
      } else {
        paymentPart = text
            .replaceAll('Payment Mode:', '')
            .replaceAll('Payment:', '')
            .replaceAll('[', '')
            .replaceAll(']', '')
            .trim();
      }

      final finalPaymentText =
          paymentTextFromList.isNotEmpty
              ? paymentTextFromList
              : paymentPart;

      return {
        'hasPayment': finalPaymentText.isNotEmpty,
        'paymentText': finalPaymentText,
        'noteText': notePart,
      };
    }

    return {
      'hasPayment': paymentTextFromList.isNotEmpty,
      'paymentText': paymentTextFromList,
      'noteText': text,
    };
  }

  static pw.Widget _buildTermsAndTotals({
    required double grossTotal,
    required double totalDiscount,
    required double taxAmount,
    required double netPayable,
    required String? remarks,
    List<Map<String, dynamic>>? paymentMethods,
  }) {
    final parsed = _parseRemarks(remarks, paymentMethods);
    final bool hasPayment = parsed['hasPayment'] as bool;
    final String paymentText = parsed['paymentText'] as String;
    final String noteText = parsed['noteText'] as String;

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          flex: 5,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Terms & Conditions', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
              pw.Text('All Cheques to be Drawn in Favor Of "MITAHARA PRIVATE LIMITED"', style: const pw.TextStyle(fontSize: 7)),
              pw.SizedBox(height: 5),
              if (hasPayment && paymentText.isNotEmpty) ...[
                pw.SizedBox(height: 10),
                pw.Container(
                  padding: const pw.EdgeInsets.all(8),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(
                      color: PdfColors.blueGrey300,
                      width: 0.8,
                    ),
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(4),
                    ),
                    color: PdfColors.blueGrey50,
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'Payment Details:',
                        style: pw.TextStyle(
                          fontSize: 8.5,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.blueGrey900,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      ...paymentText.split(', ').map(
                        (item) => pw.Padding(
                          padding: const pw.EdgeInsets.only(left: 4, top: 1),
                          child: pw.Text(
                            '• ${item.trim()}',
                            style: pw.TextStyle(
                              fontSize: 8,
                              fontWeight: pw.FontWeight.bold,
                              color: PdfColors.black,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (noteText.isNotEmpty) ...[
                pw.SizedBox(height: 8),
                pw.Text(
                  'Remarks: $noteText',
                  style: const pw.TextStyle(fontSize: 8),
                ),
              ],
            ],
          ),
        ),

        pw.SizedBox(width: 16),
        pw.Expanded(
          flex: 4,
          child: pw.Column(
            children: [
              _totalRow('Gross Total (MRP Subtotal)', grossTotal),
              _totalRow('Total Discount', -totalDiscount),
              if (taxAmount > 0) _totalRow('Tax', taxAmount),
              pw.SizedBox(height: 4),
              pw.Container(
                decoration: pw.BoxDecoration(
                  color: PdfColors.white,
                  border: pw.Border.all(color: PdfColors.black, width: 1),
                ),
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 7,
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Net Payable Amount',
                      style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.black,
                      ),
                    ),
                    pw.Text(
                      _money.format(netPayable),
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.black,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _bullet(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 10,
            child: pw.Text('•', style: const pw.TextStyle(fontSize: 8)),
          ),
          pw.Expanded(
            child: pw.Text(text, style: const pw.TextStyle(fontSize: 8)),
          ),
        ],
      ),
    );
  }

  static pw.Widget _totalRow(String label, double value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 3),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: const pw.TextStyle(fontSize: 8.5)),
          pw.Text(
            _money.format(value),
            style: const pw.TextStyle(fontSize: 8.5),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildSignatures(String salesmanName) {
    pw.Widget sigBlock(String label, {String? name}) {
      return pw.Column(
          children: [
            pw.SizedBox(height: 100),
            pw.Container(
              width: 160,
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(
                    color: PdfColors.grey600,
                    width: 0.8,
                    style: pw.BorderStyle.dotted,
                  ),
                ),
              ),
              padding: const pw.EdgeInsets.only(bottom: 4),
              child: pw.Text(
                name ?? '',
                style: const pw.TextStyle(fontSize: 8),
                textAlign: pw.TextAlign.center,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              label,
              style: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                letterSpacing: 0.3,
              ),
            ),
          ],
        );
    }

    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.end,
      children: [
        sigBlock('Receiver\'s seal and signature', name: ''),
      ],
    );
  }
}

class _SalesOrderLine {
  const _SalesOrderLine({
    required this.code,
    required this.description,
    required this.qty,
    required this.price,
    required this.discount,
    required this.amount,
  });

  final String code;
  final String description;
  final double qty;
  final double price;
  final double discount;
  final double amount;
}
