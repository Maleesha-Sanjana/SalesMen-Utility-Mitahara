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

    // Standard 80mm thermal printer printable width is ~72mm
    final format = PdfPageFormat(
      72 * PdfPageFormat.mm,
      double.infinity,
      marginAll: 2 * PdfPageFormat.mm,
    );

    final timeFormat = DateFormat('hh:mm a');

    // Customer details
    final customerName = customer['name']?.toString() ?? '';
    final customerPhone = customer['phone']?.toString() ?? customer['mobile']?.toString() ?? '';
    final customerAddress = customer['address']?.toString() ?? customer['address1']?.toString() ?? '';

    pdf.addPage(
      pw.Page(
        pageFormat: format,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // 1. Logo
              if (logoImage != null)
                pw.Center(
                  child: pw.Container(
                    height: 40,
                    child: pw.Image(logoImage),
                  ),
                ),
              pw.SizedBox(height: 5),

              // 2. Company Details (Centered)
              pw.Center(
                child: pw.Column(
                  children: [
                    pw.Text(
                      CompanyInfo.name,
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    if (CompanyInfo.addressLine1.isNotEmpty)
                      pw.Text(CompanyInfo.addressLine1, style: const pw.TextStyle(fontSize: 8)),
                    if (CompanyInfo.addressLine2.isNotEmpty)
                      pw.Text(CompanyInfo.addressLine2, style: const pw.TextStyle(fontSize: 8)),
                    if (CompanyInfo.registrationNumber.isNotEmpty)
                      pw.Text(CompanyInfo.registrationNumber, style: const pw.TextStyle(fontSize: 8)),
                    pw.Text('Ph.No.: ${CompanyInfo.phone}', style: const pw.TextStyle(fontSize: 8)),
                    if (CompanyInfo.email.isNotEmpty)
                      pw.Text('Email: ${CompanyInfo.email}', style: const pw.TextStyle(fontSize: 8)),
                  ],
                ),
              ),
              pw.SizedBox(height: 5),
              pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),
              pw.SizedBox(height: 5),

              // 3. Document Type (Invoice)
              pw.Center(
                child: pw.Text(
                  docType.toUpperCase(),
                  style: pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.SizedBox(height: 5),

              // 4. Customer & Invoice Info
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  // Left side
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        if (customerName.isNotEmpty)
                          pw.Text(customerName, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                        if (customerPhone.isNotEmpty)
                          pw.Text('Ph.No.: $customerPhone', style: const pw.TextStyle(fontSize: 8)),
                        pw.SizedBox(height: 2),
                        pw.Text('Bill To:', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                        if (customerName.isNotEmpty)
                          pw.Text(customerName, style: const pw.TextStyle(fontSize: 8)),
                        if (customerAddress.isNotEmpty)
                          pw.Text(customerAddress, style: const pw.TextStyle(fontSize: 8)),
                      ],
                    ),
                  ),
                  // Right side
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text('Date: ${_date.format(documentDate)}', style: const pw.TextStyle(fontSize: 8)),
                        pw.Text('Time: ${timeFormat.format(documentDate)}', style: const pw.TextStyle(fontSize: 8)),
                        pw.Text('Invoice No: $documentNo', style: const pw.TextStyle(fontSize: 8)),
                      ],
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 5),
              pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),

              // 5. Items Header
              pw.Row(
                children: [
                  pw.SizedBox(width: 15, child: pw.Text('#', style: pw.TextStyle(fontSize: 6, fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(flex: 4, child: pw.Text('Name', style: pw.TextStyle(fontSize: 6, fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(flex: 2, child: pw.Text('Qty', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 6, fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(flex: 2, child: pw.Text('Price', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 6, fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(flex: 3, child: pw.Text('Amount', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 6, fontWeight: pw.FontWeight.bold))),
                ],
              ),
              pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),
              pw.SizedBox(height: 2),

              // 6. Items List
              ...rows.asMap().entries.map((entry) {
                final index = entry.key + 1;
                final row = entry.value;
                final qty = double.tryParse(row['qty']?.toString() ?? '0') ?? 0.0;
                final price = double.tryParse(row['price']?.toString() ?? '0') ?? 0.0;
                final itemName = _productName(row);
                final unit = row['unit'] ?? 'Pac'; // Fallback if no unit
                
                final lineTotal = (price * qty); // Using simple price*qty to match amount, subtract discount if needed
                
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
                
                final finalAmount = row['amount'] != null 
                    ? double.tryParse(row['amount'].toString()) ?? (lineTotal - lineDiscVal)
                    : (lineTotal - lineDiscVal);

                return pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.SizedBox(width: 15, child: pw.Text('$index', style: const pw.TextStyle(fontSize: 6))),
                        pw.Expanded(
                          flex: 4, 
                          child: pw.Text(
                            itemName, 
                            style: const pw.TextStyle(fontSize: 6),
                            maxLines: 1,
                            overflow: pw.TextOverflow.clip,
                          ),
                        ),
                        pw.Expanded(flex: 2, child: pw.Text(qty.toStringAsFixed(0), textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 6))),
                        pw.Expanded(flex: 2, child: pw.Text(price > 0 ? _money.format(price) : '', textAlign: pw.TextAlign.right, style: const pw.TextStyle(fontSize: 6))),
                        pw.Expanded(flex: 3, child: pw.Text(_money.format(finalAmount), textAlign: pw.TextAlign.right, style: const pw.TextStyle(fontSize: 6))),
                      ],
                    ),
                    if (lineDiscVal > 0)
                      pw.Container(
                        alignment: pw.Alignment.centerRight,
                        child: pw.Text('Disc: -${_money.format(lineDiscVal)}', style: const pw.TextStyle(fontSize: 6)),
                      ),
                    pw.SizedBox(height: 2),
                  ],
                );
              }),
              
              pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),
              
              // 7. Totals
              pw.Row(
                children: [
                  pw.Expanded(flex: 4, child: pw.Text('Total', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(flex: 2, child: pw.Text('${rows.fold<double>(0, (sum, row) => sum + (double.tryParse(row['qty']?.toString() ?? '0') ?? 0)).toStringAsFixed(0)}', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(flex: 5, child: pw.Text(_money.format(netAmount), textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold))),
                ],
              ),
              pw.SizedBox(height: 5),

              // Breakdown
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 30),
                child: pw.Column(
                  children: [
                    if (subtotal != netAmount)
                      _buildTotalsBreakdownRow('Subtotal', subtotal),
                    if (billDiscountAmount > 0)
                      _buildTotalsBreakdownRow('Discount', -billDiscountAmount),
                    if (taxAmount > 0)
                      _buildTotalsBreakdownRow('Tax', taxAmount),
                    _buildTotalsBreakdownRow('Total', netAmount),
                    _buildTotalsBreakdownRow('Received', 0.00), // Placeholder for received amount if payments are tracked
                    _buildTotalsBreakdownRow('Balance', netAmount),
                  ],
                ),
              ),

              pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),

              // 8. Terms & Conditions
              pw.Text('Terms & Conditions', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
              pw.Text('All Cheques to be Drawn in Favor Of "MITAHARA PRIVATE LIMITED"', style: const pw.TextStyle(fontSize: 7)),
              pw.SizedBox(height: 5),
              pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),
              pw.SizedBox(height: 10),

              // 9. Footer Sign & Seal
              pw.SizedBox(height: 80), // Space for seal and sign ABOVE the label
              pw.Align(
                alignment: pw.Alignment.centerRight,
                child: pw.Text("Receiver's Seal & Sign", style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
              ),
              pw.SizedBox(height: 15),
              pw.Text('Thanks for doing business with us !', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),
              pw.Center(
                child: pw.Column(
                  children: [
                    pw.Text('System By Jazz Business Solution (pvt)Ltd', style: pw.TextStyle(fontSize: 6)),
                    pw.SizedBox(height: 2),
                    pw.Text('(c) www.jazz.lk TEL.0112886832/0777785523', style: pw.TextStyle(fontSize: 6)),
                  ]
                )
              ),
              pw.SizedBox(height: 10),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  static pw.Widget _buildTotalsBreakdownRow(String label, double amount) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Expanded(child: pw.Text(label, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold))),
        pw.Text(':', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
        pw.Expanded(child: pw.Text(_money.format(amount), textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold))),
      ],
    );
  }

  static String _productName(Map<String, dynamic> row) {
    final name = (row['productName'] ?? row['item_name'] ?? row['name'])?.toString().trim() ?? '';
    if (name.isNotEmpty) return name.toUpperCase();
    final item = row['item']?.toString() ?? '';
    if (item.contains('•')) {
      return item.split('•').skip(1).join('•').trim().toUpperCase();
    }
    return item.toUpperCase();
  }
}

