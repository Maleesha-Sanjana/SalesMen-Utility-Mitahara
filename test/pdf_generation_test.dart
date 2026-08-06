import 'package:flutter_test/flutter_test.dart';
import 'package:salesman_utility/services/invoice_pdf_generator.dart';
import 'package:salesman_utility/services/sales_order_pdf_generator.dart';
import 'package:salesman_utility/services/quotation_pdf_generator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sampleRows = [
    {
      'item': 'AFTER SUNSET • 056000',
      'qty': 2,
      'unitPrice': 4950.0,
      'wholeSalePrice': 4500.0,
    },
    {
      'item': 'Test Product සිංහල',
      'qty': 1,
      'unitPrice': 3950.0,
      'wholeSalePrice': 3800.0,
    },
  ];

  double getPriceFromRow(Map<String, dynamic> row) {
    return (row['unitPrice'] as num?)?.toDouble() ?? 0.0;
  }

  group('PDF generation', () {
    test('invoice PDF bytes build without error', () async {
      await InvoicePdfGenerator.generatePDF(
        documentNo: '01IN00000397',
        documentDate: DateTime(2026, 7, 1),
        customer: {'name': 'Test Customer', 'address': 'Colombo'},
        rows: sampleRows,
        subtotal: 13850,
        billDiscountAmount: 0,
        discountedAmount: 13850,
        taxAmount: 2077.5,
        netAmount: 15927.5,
        remarks: 'Thank you',
        salesmanName: 'Sahan',
        getPriceFromRow: getPriceFromRow,
        payments: [
          {
            'paymentCode': '003',
            'amount': 10000.0,
            'cardChequeNo': '4111111111111111',
            'currencyCode': 'LKR',
            'creditPeriod': 0,
            'bankName': '',
            'branchName': '',
          },
          {
            'paymentCode': '001',
            'amount': 5927.5,
            'cardChequeNo': '',
            'currencyCode': 'LKR',
            'creditPeriod': 0,
            'bankName': '',
            'branchName': '',
          },
        ],
        paymentDetails: {
          'Amount': 10000.0,
          'Card Number': '4111111111111111',
          'RemainingAmount': 5927.5,
          'RemainingPaymentMethod': 'cash',
        },
        preview: false,
      );
    });

    test('sales order PDF bytes build without error (no payment mode)', () async {
      await SalesOrderPdfGenerator.generatePDF(
        documentNo: '01SO00000003',
        documentDate: DateTime(2026, 7, 1),
        customer: {'name': 'Test Customer', 'address': 'Colombo'},
        rows: sampleRows,
        subtotal: 13850,
        billDiscountAmount: 0,
        discountedAmount: 13850,
        taxAmount: 0,
        netAmount: 13850,
        remarks: null,
        salesmanName: 'Sahan',
        poNumber: 'PO-123',
        getPriceFromRow: getPriceFromRow,
        preview: false,
      );
    });

    test('sales order PDF bytes build with payment modes selected', () async {
      await SalesOrderPdfGenerator.generatePDF(
        documentNo: '01SO00000004',
        documentDate: DateTime(2026, 7, 1),
        customer: {'name': 'Test Customer', 'address': 'Colombo'},
        rows: sampleRows,
        subtotal: 3000,
        billDiscountAmount: 0,
        discountedAmount: 3000,
        taxAmount: 0,
        netAmount: 3000,
        remarks: 'Payment Mode: Cash (Rs. 2000.00), Card (Rs. 1000.00) | Note: Handle with care',
        salesmanName: 'Sahan',
        poNumber: 'PO-124',
        getPriceFromRow: getPriceFromRow,
        preview: false,
        paymentMethods: [
          {'mode': 'Cash', 'amount': 2000.0},
          {'mode': 'Card', 'amount': 1000.0},
        ],
      );
    });

    test('quotation PDF bytes build without error', () async {
      await QuotationPdfGenerator.generatePDF(
        documentNo: '01QT00000001',
        documentDate: DateTime(2026, 7, 1),
        customer: {'name': 'Test Customer', 'address': 'Colombo'},
        rows: sampleRows,
        subtotal: 13850,
        billDiscountAmount: 0,
        discountedAmount: 13850,
        taxAmount: 0,
        netAmount: 13850,
        remarks: null,
        salesmanName: 'Sahan',
        reference: 'REF-1',
        getPriceFromRow: getPriceFromRow,
        preview: false,
      );
    });
  });
}
