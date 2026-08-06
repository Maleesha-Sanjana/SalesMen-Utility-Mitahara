import 'package:flutter/material.dart';

import 'admin_document_history_page.dart';

class AdminHistoryQuotationPage extends StatelessWidget {
  const AdminHistoryQuotationPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  Widget build(BuildContext context) {
    return AdminDocumentHistoryPage(
      title: 'Quotation history report',
      documentType: 'quotation',
      icon: Icons.request_quote_rounded,
      accentColor: const Color(0xFF8B5CF6),
      emptyMessage: 'No quotations found for the selected filters.',
      appBarLeading: appBarLeading,
    );
  }
}
