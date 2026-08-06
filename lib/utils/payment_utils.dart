import 'package:flutter/material.dart';

class PaymentUtils {
  // Get icon for payment method
  static IconData getPaymentIcon(String methodId) {
    switch (methodId.toLowerCase()) {
      case 'cash':
        return Icons.money_rounded;
      case 'master_card':
        return Icons.credit_card_rounded;
      case 'visa_card':
        return Icons.credit_card_rounded;
      case 'amex_card':
        return Icons.credit_card_rounded;
      case 'credit':
        return Icons.account_balance_rounded;
      case 'cheque':
        return Icons.description_rounded;
      case 'third_party_cheque':
        return Icons.description_rounded;
      case 'cod':
        return Icons.local_shipping_rounded;
      case 'direct_deposit':
        return Icons.account_balance_wallet_rounded;
      case 'online':
        return Icons.payment_rounded;
      default:
        return Icons.payment_rounded;
    }
  }

  // Map payment method names to payment codes
  static String getPaymentCode(String? methodName) {
    if (methodName == null) return '001'; // Cash default

    const Map<String, String> paymentCodeMap = {
      'cash': '001',
      'master_card': '002',
      'visa_card': '003',
      'amex_card': '004',
      'credit': '006',
      'cheque': '007',
      'third_party_cheque': '007',
      'cod': '001',
      'direct_deposit': '008',
      'online': '009',
    };

    return paymentCodeMap[methodName.toLowerCase()] ?? '001';
  }

  static String paymentCodeToLabel(String? code) {
    switch (code) {
      case '001':
        return 'Cash';
      case '002':
        return 'Master Card';
      case '003':
        return 'Visa Card';
      case '004':
        return 'Amex Card';
      case '006':
        return 'Credit';
      case '007':
        return 'Cheque';
      case '008':
        return 'Direct Deposit';
      case '009':
        return 'Online';
      default:
        return code ?? 'Payment';
    }
  }

  static String methodIdToLabel(String? methodId) {
    if (methodId == null || methodId.isEmpty) return 'Payment';
    switch (methodId.toLowerCase()) {
      case 'cash':
        return 'Cash';
      case 'master_card':
        return 'Master Card';
      case 'visa_card':
        return 'Visa Card';
      case 'amex_card':
        return 'Amex Card';
      case 'credit':
        return 'Credit';
      case 'cheque':
        return 'Cheque';
      case 'third_party_cheque':
        return 'Third Party Cheque';
      case 'cod':
        return 'COD';
      case 'direct_deposit':
        return 'Direct Deposit';
      case 'online':
        return 'Online';
      default:
        return methodId;
    }
  }

  /// Builds human-readable payment rows for invoice PDF output.
  static List<Map<String, String>> buildPdfPaymentRows({
    required List<Map<String, dynamic>> payments,
    Map<String, dynamic>? paymentDetails,
  }) {
    final rows = <Map<String, String>>[];

    for (var i = 0; i < payments.length; i++) {
      final payment = payments[i];
      final code = payment['paymentCode']?.toString() ?? '';
      final amount = (payment['amount'] as num?)?.toDouble() ?? 0.0;
      final detailParts = <String>{};

      if (i == 0 && paymentDetails != null) {
        detailParts.addAll(_paymentDetailsParts(paymentDetails));
      } else if (i == 1 &&
          paymentDetails?['RemainingPaymentDetails'] is Map<String, dynamic>) {
        detailParts.addAll(
          _paymentDetailsParts(
            Map<String, dynamic>.from(
              paymentDetails!['RemainingPaymentDetails'] as Map,
            ),
          ),
        );
      }

      detailParts.addAll(_paymentEntryDetailParts(payment));

      rows.add({
        'type': paymentCodeToLabel(code),
        'amount': amount.toStringAsFixed(2),
        'details': detailParts.join(' • '),
      });
    }

    if (paymentDetails != null) {
      final remainingMethod =
          paymentDetails['RemainingPaymentMethod']?.toString();
      if (remainingMethod != null &&
          remainingMethod.isNotEmpty &&
          payments.length <= 1) {
        final remainingAmount =
            (paymentDetails['RemainingAmount'] as num?)?.toDouble();
        if (remainingAmount != null && remainingAmount > 0) {
          final remDetails = paymentDetails['RemainingPaymentDetails'];
          rows.add({
            'type': methodIdToLabel(remainingMethod),
            'amount': remainingAmount.toStringAsFixed(2),
            'details': remDetails is Map<String, dynamic>
                ? _paymentDetailsParts(remDetails).join(' • ')
                : '',
          });
        }
      }
    }

    return rows;
  }

  static List<String> _paymentEntryDetailParts(Map<String, dynamic> payment) {
    final parts = <String>[];
    final cardCheque = payment['cardChequeNo']?.toString().trim() ?? '';
    if (cardCheque.isNotEmpty) {
      parts.add('Ref: $cardCheque');
    }

    final bank = payment['bankName']?.toString().trim() ?? '';
    if (bank.isNotEmpty) {
      parts.add('Bank: $bank');
    }

    final branch = payment['branchName']?.toString().trim() ?? '';
    if (branch.isNotEmpty) {
      parts.add('Branch: $branch');
    }

    final chequeDate = payment['chequeDate']?.toString().trim();
    if (chequeDate != null && chequeDate.isNotEmpty) {
      parts.add('Cheque Date: $chequeDate');
    }

    final creditPeriod = (payment['creditPeriod'] as num?)?.toInt() ?? 0;
    if (payment['paymentCode']?.toString() == '006' && creditPeriod > 0) {
      parts.add('Credit Period: $creditPeriod days');
    }

    final currency = payment['currencyCode']?.toString().trim();
    if (currency != null && currency.isNotEmpty && currency != 'LKR') {
      parts.add('Currency: $currency');
    }

    return parts;
  }

  static List<String> _paymentDetailsParts(Map<String, dynamic> details) {
    final parts = <String>[];
    const skipKeys = {
      'Amount',
      'RemainingAmount',
      'RemainingPaymentMethod',
      'RemainingPaymentDetails',
    };

    for (final entry in details.entries) {
      if (skipKeys.contains(entry.key)) continue;
      final value = entry.value?.toString().trim() ?? '';
      if (value.isEmpty) continue;
      parts.add('${entry.key}: $value');
    }

    return parts;
  }
}

