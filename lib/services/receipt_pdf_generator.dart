import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'company_info.dart';

class ReceiptPdfGenerator {
  static final _money = NumberFormat('#,##0.00');
  static final _date = DateFormat('M/d/yyyy');

  static Future<Uint8List> generateReceiptPDF({
    required String docType, // 'Sales Order', 'Quotation', 'Invoice', 'CRN'
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
    List<Map<String, dynamic>>? paymentModes,
  }) async {
    final pdf = pw.Document();
    
    // Load logo if exists
    pw.ImageProvider? logoImage;
    try {
      final logoBytes = await rootBundle.load('assets/allsoLogo.png');
      logoImage = pw.MemoryImage(logoBytes.buffer.asUint8List());
    } catch (e) {
      // Ignore if logo not found
    }

    // 104mm width for TechnoPos TP-P816
    final format = PdfPageFormat(
      104 * PdfPageFormat.mm,
      double.infinity,
      marginAll: 2 * PdfPageFormat.mm,
    );

    pdf.addPage(
      pw.Page(
        pageFormat: format,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Header
              pw.Center(
                child: pw.Column(
                  children: [
                    if (logoImage != null)
                      pw.Container(
                        height: 40,
                        child: pw.Image(logoImage),
                      ),
                    pw.SizedBox(height: 5),
                    pw.Text(
                      CompanyInfo.name,
                      style: pw.TextStyle(
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                      ),
                      textAlign: pw.TextAlign.center,
                    ),
                    pw.Text(CompanyInfo.addressLine1, style: const pw.TextStyle(fontSize: 10)),
                    pw.Text(CompanyInfo.addressLine2, style: const pw.TextStyle(fontSize: 10)),
                    pw.Text('Tel: ${CompanyInfo.phone}', style: const pw.TextStyle(fontSize: 10)),
                    pw.SizedBox(height: 5),
                    pw.Text(
                      docType.toUpperCase(),
                      style: pw.TextStyle(
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                        decoration: pw.TextDecoration.underline,
                      ),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 10),
              
              // Document Info
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Doc No: $documentNo', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                  pw.Text('Date: ${_date.format(documentDate)}', style: const pw.TextStyle(fontSize: 10)),
                ],
              ),
              pw.SizedBox(height: 2),
              pw.Text('Customer: ${customer['name'] ?? ''}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text('Code: ${customer['code'] ?? ''}', style: const pw.TextStyle(fontSize: 10)),
              if (customer['address1'] != null && customer['address1'].toString().isNotEmpty)
                pw.Text('Address: ${customer['address1']}', style: const pw.TextStyle(fontSize: 10)),
              pw.SizedBox(height: 2),
              pw.Text('Salesman: $salesmanName', style: const pw.TextStyle(fontSize: 10)),
              if (poNumber != null && poNumber.isNotEmpty)
                pw.Text('PO Number: $poNumber', style: const pw.TextStyle(fontSize: 10)),
              pw.SizedBox(height: 5),
              pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),

              // Items Header
              pw.Row(
                children: [
                  pw.Expanded(flex: 3, child: pw.Text('Item', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(flex: 1, child: pw.Text('Qty', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(flex: 2, child: pw.Text('Price', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(flex: 2, child: pw.Text('Total', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
                ],
              ),
              pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),
              pw.SizedBox(height: 2),

              // Items
              ...rows.map((row) {
                final qty = double.tryParse(row['qty']?.toString() ?? '0') ?? 0.0;
                final price = double.tryParse(row['price']?.toString() ?? '0') ?? 0.0;
                final itemName = row['productName'] ?? row['item_name'] ?? '';
                final itemCode = row['productCode'] ?? row['item_code'] ?? '';
                
                // Line discount logic
                final rawDisc = row['discount']?.toString() ?? '0';
                final numDisc = double.tryParse(rawDisc.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
                double lineDiscVal = 0.0;
                if (numDisc > 0) {
                  if (rawDisc.contains('%')) {
                    lineDiscVal = price * qty * (numDisc / 100);
                  } else {
                    lineDiscVal = numDisc;
                  }
                }
                
                final lineTotal = (price * qty) - lineDiscVal;

                return pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('$itemCode - $itemName', style: const pw.TextStyle(fontSize: 9)),
                    pw.Row(
                      children: [
                        pw.Expanded(flex: 3, child: pw.Container()), // indent
                        pw.Expanded(flex: 1, child: pw.Text(qty.toStringAsFixed(0), textAlign: pw.TextAlign.right, style: const pw.TextStyle(fontSize: 9))),
                        pw.Expanded(flex: 2, child: pw.Text(_money.format(price), textAlign: pw.TextAlign.right, style: const pw.TextStyle(fontSize: 9))),
                        pw.Expanded(flex: 2, child: pw.Text(_money.format(lineTotal), textAlign: pw.TextAlign.right, style: const pw.TextStyle(fontSize: 9))),
                      ],
                    ),
                    if (lineDiscVal > 0)
                      pw.Container(
                        alignment: pw.Alignment.centerRight,
                        child: pw.Text('Disc: -${_money.format(lineDiscVal)}', style: const pw.TextStyle(fontSize: 8)),
                      ),
                    pw.SizedBox(height: 2),
                  ],
                );
              }),
              
              pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),
              
              // Totals
              _buildTotalRow('Subtotal:', subtotal),
              if (billDiscountAmount > 0)
                _buildTotalRow('Discount:', billDiscountAmount),
              if (taxAmount > 0)
                _buildTotalRow('Tax:', taxAmount),
              
              pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('NET AMOUNT:', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                  pw.Text(_money.format(netAmount), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                ],
              ),
              pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),

              // Payments if any
              if (paymentModes != null && paymentModes.isNotEmpty) ...[
                pw.SizedBox(height: 5),
                pw.Text('Payments:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                ...paymentModes.map((p) {
                  final m = p['mode'] ?? '';
                  final a = double.tryParse(p['amount']?.toString() ?? '0') ?? 0.0;
                  return pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text('  $m', style: const pw.TextStyle(fontSize: 9)),
                      pw.Text(_money.format(a), style: const pw.TextStyle(fontSize: 9)),
                    ],
                  );
                }),
                pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),
              ],

              if (remarks != null && remarks.isNotEmpty) ...[
                pw.SizedBox(height: 5),
                pw.Text('Remarks:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                pw.Text(remarks, style: const pw.TextStyle(fontSize: 9)),
              ],
              
              pw.SizedBox(height: 15),
              pw.Center(
                child: pw.Text('Thank you!', style: const pw.TextStyle(fontSize: 10)),
              ),
              pw.SizedBox(height: 20),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  static pw.Widget _buildTotalRow(String label, double amount) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(label, style: const pw.TextStyle(fontSize: 10)),
        pw.Text(_money.format(amount), style: const pw.TextStyle(fontSize: 10)),
      ],
    );
  }
}
