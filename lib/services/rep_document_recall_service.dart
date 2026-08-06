import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'api_service.dart';
import 'invoice_pdf_generator.dart';
import 'quotation_pdf_generator.dart';
import 'sales_order_pdf_generator.dart';
import 'receipt_pdf_generator.dart';
import 'bluetooth_printer_service.dart';

class RepDocumentRecallService {
  static Future<Map<String, dynamic>> fetchRecall({
    required String documentType,
    required String documentNo,
    String? customerCode,
  }) async {
    switch (documentType) {
      case 'invoice':
        return ApiService.getInvoiceForRecall(
          documentNo: documentNo,
          customerCode: customerCode,
        );
      case 'sales-order':
        return ApiService.getSalesOrderForRecall(
          documentNo: documentNo,
          customerCode: customerCode,
        );
      case 'quotation':
        return ApiService.getQuotationForRecall(
          documentNo: documentNo,
          customerCode: customerCode,
        );
      case 'crn':
        return ApiService.getCrnForRecall(
          documentNo: documentNo,
          customerCode: customerCode,
        );
      default:
        throw Exception('Unsupported document type: $documentType');
    }
  }

  static Future<void> previewPdfFromHistoryEntry({
    required BuildContext context,
    required String documentType,
    required Map<String, dynamic> entry,
  }) async {
    if (entry['isPendingSync'] == true) {
      throw Exception('This document is still pending sync. Sync it first.');
    }

    final documentNo = entry['documentNo']?.toString().trim() ?? '';
    if (documentNo.isEmpty) {
      throw Exception('Document number is missing');
    }

    final auth = context.read<AuthProvider>();
    final salesmanName =
        auth.salesmanName.isNotEmpty ? auth.salesmanName : auth.salesmanCode;
    final customerCode = entry['customerCode']?.toString();
    final fallbackCustomerName = entry['customerName']?.toString() ?? customerCode ?? 'Customer';

    final recall = await fetchRecall(
      documentType: documentType,
      documentNo: documentNo,
      customerCode: customerCode,
    );

    final header = Map<String, dynamic>.from(recall['header'] as Map? ?? {});
    final details = (recall['details'] as List? ?? [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    if (details.isEmpty) {
      throw Exception('No line items found for this document');
    }

    final salesType = header['SalesType']?.toString() ?? 'Retail';
    final locaCode = _resolveLocaCode(header['LocaCode']?.toString());
    final rows = _documentDetailsToRows(details, locaCode, salesType);

    final grossAmount = _toDouble(header['GrossAmount']);
    final discAmount = _toDouble(header['DiscAmount']);
    final taxAmount = _toDouble(header['TaxAmount']);
    final netAmount = _toDouble(header['NetAmount'], fallback: _toDouble(entry['netAmount']));
    final discountedAmount = grossAmount > 0 ? grossAmount - discAmount : netAmount - taxAmount;
    final subtotal = grossAmount > 0 ? grossAmount : discountedAmount + discAmount;
    final documentDate = _parseDocumentDate(
      header['DocumentDate']?.toString() ?? entry['documentDate']?.toString(),
    );
    final remarks = header['Remarks']?.toString();
    final customer = {
      'name': header['CustomerName']?.toString().trim().isNotEmpty == true
          ? header['CustomerName'].toString()
          : fallbackCustomerName,
      'address': header['CustomerAddress']?.toString() ??
          header['Address']?.toString() ??
          '',
      'code': header['CustomerCode']?.toString() ?? customerCode ?? '',
      'creditPeriod': header['CreditPeriod']?.toString() ??
          header['creditPeriod']?.toString() ??
          '0',
    };

    double getPriceFromRow(Map<String, dynamic> row) {
      if (row.containsKey('unitPrice') && row.containsKey('wholeSalePrice')) {
        return salesType == 'Retail'
            ? _toDouble(row['unitPrice'])
            : _toDouble(row['wholeSalePrice']);
      }
      return _toDouble(row['price']);
    }

    if (!context.mounted) return;

    switch (documentType) {
      case 'invoice':
        await InvoicePdfGenerator.generatePDF(
          documentNo: documentNo,
          documentDate: documentDate,
          customer: customer,
          rows: rows,
          subtotal: subtotal,
          billDiscountAmount: discAmount,
          discountedAmount: discountedAmount,
          taxAmount: taxAmount,
          netAmount: netAmount,
          remarks: remarks,
          salesmanName: salesmanName,
          getPriceFromRow: getPriceFromRow,
          context: context,
        );
        return;
      case 'sales-order':
        await SalesOrderPdfGenerator.generatePDF(
          documentNo: documentNo,
          documentDate: documentDate,
          customer: customer,
          rows: rows,
          subtotal: subtotal,
          billDiscountAmount: discAmount,
          discountedAmount: discountedAmount,
          taxAmount: taxAmount,
          netAmount: netAmount,
          remarks: remarks,
          salesmanName: salesmanName,
          poNumber: header['Reference']?.toString(),
          getPriceFromRow: getPriceFromRow,
          context: context,
        );
        return;
      case 'quotation':
        await QuotationPdfGenerator.generatePDF(
          documentNo: documentNo,
          documentDate: documentDate,
          customer: customer,
          rows: rows,
          subtotal: subtotal,
          billDiscountAmount: discAmount,
          discountedAmount: discountedAmount,
          taxAmount: taxAmount,
          netAmount: netAmount,
          remarks: remarks,
          salesmanName: salesmanName,
          reference: header['Reference']?.toString(),
          getPriceFromRow: getPriceFromRow,
          context: context,
        );
        return;
      case 'crn':
        await InvoicePdfGenerator.generatePDF(
          documentNo: documentNo,
          documentDate: documentDate,
          customer: customer,
          rows: rows,
          subtotal: subtotal,
          billDiscountAmount: discAmount,
          discountedAmount: discountedAmount,
          taxAmount: taxAmount,
          netAmount: netAmount,
          remarks: remarks,
          salesmanName: salesmanName,
          getPriceFromRow: getPriceFromRow,
          context: context,
          documentTitle: 'CUSTOMER RETURN',
          documentNoLabel: 'CRN No',
          pdfFilenamePrefix: 'CustomerReturn',
        );
        return;
    }
  }

  static Future<void> printReceiptFromHistoryEntry({
    required BuildContext context,
    required String documentType,
    required Map<String, dynamic> entry,
  }) async {
    if (entry['isPendingSync'] == true) {
      throw Exception('This document is still pending sync. Sync it first.');
    }

    final documentNo = entry['documentNo']?.toString().trim() ?? '';
    if (documentNo.isEmpty) {
      throw Exception('Document number is missing');
    }

    final auth = context.read<AuthProvider>();
    final salesmanName =
        auth.salesmanName.isNotEmpty ? auth.salesmanName : auth.salesmanCode;
    final customerCode = entry['customerCode']?.toString();
    final fallbackCustomerName = entry['customerName']?.toString() ?? customerCode ?? 'Customer';

    final recall = await fetchRecall(
      documentType: documentType,
      documentNo: documentNo,
      customerCode: customerCode,
    );

    final header = Map<String, dynamic>.from(recall['header'] as Map? ?? {});
    final details = (recall['details'] as List? ?? [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    if (details.isEmpty) {
      throw Exception('No line items found for this document');
    }

    final salesType = header['SalesType']?.toString() ?? 'Retail';
    final locaCode = _resolveLocaCode(header['LocaCode']?.toString());
    final rows = _documentDetailsToRows(details, locaCode, salesType);

    final grossAmount = _toDouble(header['GrossAmount']);
    final discAmount = _toDouble(header['DiscAmount']);
    final taxAmount = _toDouble(header['TaxAmount']);
    final netAmount = _toDouble(header['NetAmount'], fallback: _toDouble(entry['netAmount']));
    final discountedAmount = grossAmount > 0 ? grossAmount - discAmount : netAmount - taxAmount;
    final subtotal = grossAmount > 0 ? grossAmount : discountedAmount + discAmount;
    final documentDate = _parseDocumentDate(
      header['DocumentDate']?.toString() ?? entry['documentDate']?.toString(),
    );
    final remarks = header['Remarks']?.toString();
    final customer = {
      'name': header['CustomerName']?.toString().trim().isNotEmpty == true
          ? header['CustomerName'].toString()
          : fallbackCustomerName,
      'address': header['CustomerAddress']?.toString() ??
          header['Address']?.toString() ??
          '',
      'code': header['CustomerCode']?.toString() ?? customerCode ?? '',
      'creditPeriod': header['CreditPeriod']?.toString() ??
          header['creditPeriod']?.toString() ??
          '0',
    };
    
    // Add correct pricing to rows for ReceiptPdfGenerator since it expects price/qty
    double getPriceFromRow(Map<String, dynamic> row) {
      if (row.containsKey('unitPrice') && row.containsKey('wholeSalePrice')) {
        return salesType == 'Retail'
            ? _toDouble(row['unitPrice'])
            : _toDouble(row['wholeSalePrice']);
      }
      return _toDouble(row['price']);
    }
    
    for (var row in rows) {
      row['price'] = getPriceFromRow(row);
    }

    if (!context.mounted) return;
    
    String docTypeLabel = documentType.toUpperCase();
    if (documentType == 'sales-order') docTypeLabel = 'SALES ORDER';
    else if (documentType == 'crn') docTypeLabel = 'CUSTOMER RETURN';

    final pdfBytes = await ReceiptPdfGenerator.generateReceiptPDF(
      docType: docTypeLabel,
      documentNo: documentNo,
      documentDate: documentDate,
      customer: customer,
      rows: rows,
      subtotal: subtotal,
      billDiscountAmount: discAmount,
      discountedAmount: discountedAmount,
      taxAmount: taxAmount,
      netAmount: netAmount,
      remarks: remarks,
      salesmanName: salesmanName,
      poNumber: header['Reference']?.toString(),
      paymentModes: [],
    );

    if (context.mounted) {
      await BluetoothPrinterService.printReceipt(context, pdfBytes);
    }
  }

  static String _resolveLocaCode(String? value) {
    final raw = (value ?? '01').trim();
    if (raw.isEmpty || raw.length > 5) return '01';
    return raw;
  }

  static double _toDouble(dynamic value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static DateTime _parseDocumentDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return DateTime.now();
    final parsed = DateTime.tryParse(raw);
    return parsed ?? DateTime.now();
  }

  static Map<String, dynamic> _mapDocumentDetailToRow(
    Map<String, dynamic> detail,
    String locaCode,
    String salesType,
  ) {
    final qty =
        _toDouble(detail['Qty']) > 0
            ? _toDouble(detail['Qty'])
            : _toDouble(detail['BQTY']);
    final unitPrice = _toDouble(detail['UnitPrice']);
    final wholeSalePrice =
        _toDouble(detail['WholeSalePrice'], fallback: unitPrice);
    final price = salesType == 'Retail' ? unitPrice : wholeSalePrice;
    final productCode = detail['ProductCode']?.toString() ?? '';
    final productName = detail['ProductDescription']?.toString() ?? '';

    return {
      'code': productCode,
      'name': productName,
      'item': '$productCode • $productName',
      'longDescription': detail['LongDescription']?.toString() ?? '',
      'qty': qty,
      'freeQty': _toDouble(detail['FreeQty']),
      'uom': detail['Unit']?.toString() ?? 'PCS',
      'packSize': _toDouble(detail['PackSize'], fallback: 1),
      'margin': _toDouble(detail['Margin']),
      'costPrice': _toDouble(detail['CostPrice']),
      'unitPrice': unitPrice,
      'wholeSalePrice': wholeSalePrice,
      'price': price,
      'batchNo': detail['BatchNo']?.toString() ?? '',
      'expiryDate': detail['ExpiryDate']?.toString(),
      'discount': _toDouble(detail['DiscPer']) > 0
          ? '${_toDouble(detail['DiscPer']).toStringAsFixed(2)}%'
          : _toDouble(detail['DiscAmount']).toString(),
      'stockLoca': detail['StockLoca']?.toString().isNotEmpty == true
          ? detail['StockLoca'].toString()
          : locaCode,
      'tax': _toDouble(detail['Tax']),
    };
  }

  static List<Map<String, dynamic>> _documentDetailsToRows(
    List<Map<String, dynamic>> details,
    String locaCode,
    String salesType,
  ) {
    return details
        .map((detail) => _mapDocumentDetailToRow(detail, locaCode, salesType))
        .where((row) => row['code'].toString().isNotEmpty)
        .toList();
  }
}
