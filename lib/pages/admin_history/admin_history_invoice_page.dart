import 'package:flutter/material.dart';

import 'admin_document_history_page.dart';

class AdminHistoryInvoicePage extends StatelessWidget {
  const AdminHistoryInvoicePage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  Widget build(BuildContext context) {
    return AdminDocumentHistoryPage(
      title: 'Invoice history report',
      documentType: 'invoice',
      icon: Icons.receipt_long_rounded,
      accentColor: const Color(0xFF10B981),
      emptyMessage: 'No invoices found for the selected filters.',
      appBarLeading: appBarLeading,
    );
  }
}
