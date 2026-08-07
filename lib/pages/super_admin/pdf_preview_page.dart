import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import '../../services/invoice_pdf_generator.dart';
import '../../services/sales_order_pdf_generator.dart';
import '../../services/quotation_pdf_generator.dart';

class PdfPreviewPage extends StatefulWidget {
  const PdfPreviewPage({super.key});

  @override
  State<PdfPreviewPage> createState() => _PdfPreviewPageState();
}

class _PdfPreviewPageState extends State<PdfPreviewPage> {
  String _selectedType = 'Invoice';

  final Map<String, dynamic> dummyCustomer = {
    'name': 'John Doe (Demo)',
    'address': '123 Demo Street, Colombo',
    'phone': '0771234567',
    'creditPeriod': 30,
  };

  final List<Map<String, dynamic>> dummyRows = [
    {
      'code': 'ITM-001',
      'name': 'Demo Product A',
      'qty': 2.0,
      'discount': '0',
    },
    {
      'code': 'ITM-002',
      'name': 'Demo Product B',
      'qty': 1.0,
      'discount': '10%',
    },
    {
      'code': 'ITM-003',
      'name': 'Demo Service',
      'qty': 3.0,
      'discount': '150',
    },
  ];

  double _getPrice(Map<String, dynamic> row) {
    switch (row['code']) {
      case 'ITM-001':
        return 1200.0;
      case 'ITM-002':
        return 5000.0;
      case 'ITM-003':
        return 500.0;
      default:
        return 0.0;
    }
  }

  Future<Uint8List> _generatePdf() async {
    switch (_selectedType) {
      case 'Sales Order':
        return await SalesOrderPdfGenerator.generatePDF(
          documentNo: 'SO-DEMO-001',
          documentDate: DateTime.now(),
          customer: dummyCustomer,
          rows: dummyRows,
          subtotal: 8900.0,
          billDiscountAmount: 0.0,
          discountedAmount: 0.0,
          taxAmount: 0.0,
          netAmount: 8250.0,
          remarks: 'This is a demo sales order.',
          salesmanName: 'Demo Salesman',
          getPriceFromRow: _getPrice,
          preview: false,
          poNumber: 'PO-001',
        );
      case 'Quotation':
        return await QuotationPdfGenerator.generatePDF(
          documentNo: 'QT-DEMO-001',
          documentDate: DateTime.now(),
          customer: dummyCustomer,
          rows: dummyRows,
          subtotal: 8900.0,
          billDiscountAmount: 0.0,
          discountedAmount: 0.0,
          taxAmount: 0.0,
          netAmount: 8250.0,
          remarks: 'This is a demo quotation.',
          salesmanName: 'Demo Salesman',
          getPriceFromRow: _getPrice,
          preview: false,
          validityDaysOverride: 14,
        );
      case 'CRN':
        return await InvoicePdfGenerator.generatePDF(
          documentNo: 'CRN-DEMO-001',
          documentDate: DateTime.now(),
          customer: dummyCustomer,
          rows: dummyRows,
          subtotal: 8900.0,
          billDiscountAmount: 0.0,
          discountedAmount: 0.0,
          taxAmount: 0.0,
          netAmount: 8250.0,
          remarks: 'This is a demo CRN.',
          salesmanName: 'Demo Salesman',
          getPriceFromRow: _getPrice,
          preview: false,
          documentTitle: 'CUSTOMER RETURN NOTE',
          documentNoLabel: 'CRN No',
          pdfFilenamePrefix: 'CRN',
        );
      case 'Invoice':
      default:
        return await InvoicePdfGenerator.generatePDF(
          documentNo: 'INV-DEMO-001',
          documentDate: DateTime.now(),
          customer: dummyCustomer,
          rows: dummyRows,
          subtotal: 8900.0,
          billDiscountAmount: 0.0,
          discountedAmount: 0.0,
          taxAmount: 0.0,
          netAmount: 8250.0,
          remarks: 'This is a demo invoice for layout preview purposes.',
          salesmanName: 'Demo Salesman',
          getPriceFromRow: _getPrice,
          preview: false,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF View Preview'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: DropdownButton<String>(
              value: _selectedType,
              dropdownColor: Theme.of(context).cardColor,
              underline: const SizedBox(),
              items: ['Invoice', 'CRN', 'Sales Order', 'Quotation']
                  .map((type) => DropdownMenuItem(
                        value: type,
                        child: Text(
                          type,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ))
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _selectedType = value;
                  });
                }
              },
            ),
          )
        ],
      ),
      body: PdfPreview(
        key: ValueKey(_selectedType),
        build: (format) => _generatePdf(),
        canChangeOrientation: false,
        canChangePageFormat: false,
        allowSharing: true,
        allowPrinting: true,
        pdfFileName: '${_selectedType}_Preview.pdf',
      ),
    );
  }
}

