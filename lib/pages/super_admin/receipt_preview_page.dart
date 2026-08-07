import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import '../../services/receipt_pdf_generator.dart';

class ReceiptPreviewPage extends StatefulWidget {
  const ReceiptPreviewPage({super.key});

  @override
  State<ReceiptPreviewPage> createState() => _ReceiptPreviewPageState();
}

class _ReceiptPreviewPageState extends State<ReceiptPreviewPage> {
  final Map<String, dynamic> dummyCustomer = {
    'name': 'John Doe (Demo)',
    'address': '123 Demo Street, Colombo',
    'phone': '0771234567',
  };

  final List<Map<String, dynamic>> dummyRows = [
    {
      'name': 'Demo Product A',
      'qty': 2.0,
      'price': 1200.0,
      'discount': '0',
    },
    {
      'name': 'Demo Product B',
      'qty': 1.0,
      'price': 5000.0,
      'discount': '10%',
    },
    {
      'name': 'Demo Service',
      'qty': 3.0,
      'price': 500.0,
      'discount': '150',
    },
  ];

  Future<Uint8List> _generateReceipt() async {
    return await ReceiptPdfGenerator.generateReceiptPDF(
      docType: 'Invoice',
      documentNo: 'INV-DEMO-001',
      documentDate: DateTime.now(),
      customer: dummyCustomer,
      rows: dummyRows,
      subtotal: 8900.0,
      billDiscountAmount: 0.0,
      discountedAmount: 0.0,
      taxAmount: 0.0,
      netAmount: 8250.0,
      remarks: 'This is a demo receipt for layout preview purposes.',
      salesmanName: 'Demo Salesman',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receipt View Preview'),
      ),
      body: PdfPreview(
        build: (format) => _generateReceipt(),
        canChangeOrientation: false,
        canChangePageFormat: false,
        allowSharing: true,
        allowPrinting: true,
        pdfFileName: 'Receipt_Preview.pdf',
      ),
    );
  }
}
