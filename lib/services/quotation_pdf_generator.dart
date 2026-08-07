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

class QuotationPdfGenerator {
  static const int validityDays = 14;

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
    // 0787678767 / 0785758575 -> 078-7678767 / 078-5758575
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
    String? reference,
    int? validityDaysOverride,
    required double Function(Map<String, dynamic>) getPriceFromRow,
    BuildContext? context,
    bool preview = true,
  }) async {
    final theme = await PdfFonts.documentTheme();
    final pdf = pw.Document(theme: theme);

    final logoData = await rootBundle.load('assets/allsoLogo.png');
    final logoImage = pw.MemoryImage(logoData.buffer.asUint8List());

    final days = validityDaysOverride ?? validityDays;
    final validUntil = documentDate.add(Duration(days: days));
    final creditDays = _creditPeriodDays(customer);

    final customerSectionLabel = _customerSectionLabel(customer);
    final customerLine = _customerDetailLine(customer);

    var grossTotal = 0.0;
    var lineDiscountTotal = 0.0;
    final lineRows = <_QuotationLine>[];
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
        _QuotationLine(
          code: _productCode(row),
          description: _productName(row),
          qty: qty,
          price: price,
          discount: discount,
          amount: amount,
        ),
      );
    }

    // Prefer computed MRP gross; fall back to provided subtotal if rows empty.
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
              validUntil: validUntil,
              validityDays: days,
              creditDays: creditDays,
            ),
            pw.SizedBox(height: 16),
            _buildCustomerBlock(
              customerLine,
              label: customerSectionLabel,
            ),
            pw.SizedBox(height: 14),
            _buildItemsTable(lineRows),
            pw.SizedBox(height: 16),
            _buildTermsAndTotals(
              validityDays: days,
              grossTotal: grossTotal,
              totalDiscount: totalDiscount,
              taxAmount: taxAmount,
              netPayable: payable,
              remarks: remarks,
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
        filename: 'Quotation_$documentNo.pdf',
      );
      return bytes;
    }

    return bytes;
  }

  static pw.Widget _buildHeader({
    required pw.MemoryImage logoImage,
    required String documentNo,
    required DateTime documentDate,
    required DateTime validUntil,
    required int validityDays,
    required int creditDays,
  }) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Stack(
                children: [
                  pw.Positioned(left: -0.5, top: -0.5, child: pw.Text('QUOTATION', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, letterSpacing: 0.5, color: PdfColors.black))),
                  pw.Positioned(left: 0.5, top: -0.5, child: pw.Text('QUOTATION', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, letterSpacing: 0.5, color: PdfColors.black))),
                  pw.Positioned(left: -0.5, top: 0.5, child: pw.Text('QUOTATION', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, letterSpacing: 0.5, color: PdfColors.black))),
                  pw.Positioned(left: 0.5, top: 0.5, child: pw.Text('QUOTATION', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, letterSpacing: 0.5, color: PdfColors.black))),
                  pw.Text('QUOTATION', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, letterSpacing: 0.5, color: PdfColors.white)),
                ],
              ),
              pw.SizedBox(height: 10),
              _metaRow('Quotation No:', documentNo),
              _metaRow('Date:', _date.format(documentDate)),
              _metaRow(
                'Validity:',
                '$validityDays Days (Until ${_date.format(validUntil)})',
              ),
              _metaRow('Credit Period:', '$creditDays Days'),
            ],
          ),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Image(logoImage, height: 36, fit: pw.BoxFit.contain, alignment: pw.Alignment.topRight),
            pw.SizedBox(height: 8),
            pw.Text(
              CompanyInfo.name,
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
              textAlign: pw.TextAlign.right,
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              '${CompanyInfo.addressLine1}, ${CompanyInfo.addressLine2}',
              style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
              textAlign: pw.TextAlign.right,
            ),
            pw.Text(
              'Tel: ${_formatPhone(CompanyInfo.phone)}',
              style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
              textAlign: pw.TextAlign.right,
            ),
            pw.Text(
              'Email: ${CompanyInfo.email}',
              style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
              textAlign: pw.TextAlign.right,
            ),
            pw.Text(
              'Reg No: ${CompanyInfo.registrationNumber}',
              style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
              textAlign: pw.TextAlign.right,
            ),
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
          pw.Text(
            value,
            style: const pw.TextStyle(fontSize: 8.5),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildCustomerBlock(
    String customerLine, {
    required String label,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          width: double.infinity,
          color: PdfColors.grey300,
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: pw.Text(
            label,
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
          child: pw.Text(
            customerLine,
            style: pw.TextStyle(
              fontSize: 9.5,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildItemsTable(List<_QuotationLine> lines) {
    final headerStyle = pw.TextStyle(
      fontSize: 7.5,
      fontWeight: pw.FontWeight.bold,
      color: PdfColors.black,
    );
    final cellStyle = const pw.TextStyle(fontSize: 7.5);

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
      border: pw.TableBorder.all(color: PdfColors.black, width: 0.5),
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

  static pw.Widget _buildTermsAndTotals({
    required int validityDays,
    required double grossTotal,
    required double totalDiscount,
    required double taxAmount,
    required double netPayable,
    required String? remarks,
  }) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          flex: 5,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (remarks != null && remarks.trim().isNotEmpty) ...[
                pw.SizedBox(height: 8),
                pw.Text(
                  'Remarks: ${remarks.trim()}',
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
      return pw.Expanded(
        child: pw.Column(
          children: [
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
        ),
      );
    }

    return pw.Row(
      children: [
        sigBlock('PREPARED BY', name: salesmanName),
      ],
    );
  }
}

class _QuotationLine {
  const _QuotationLine({
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
