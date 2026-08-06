import 'package:flutter/material.dart';

import 'rep_document_history_page.dart';

class MyHistoryInvoicePage extends StatelessWidget {
  const MyHistoryInvoicePage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  Widget build(BuildContext context) {
    return RepDocumentHistoryPage(
      title: 'Invoice history',
      documentType: 'invoice',
      icon: Icons.receipt_long_rounded,
      accentColor: const Color(0xFF10B981),
      emptyMessage: 'No invoices found for your account yet.',
      appBarLeading: appBarLeading,
    );
  }
}
