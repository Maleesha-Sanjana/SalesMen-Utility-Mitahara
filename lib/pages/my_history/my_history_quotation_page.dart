import 'package:flutter/material.dart';

import 'rep_document_history_page.dart';

class MyHistoryQuotationPage extends StatelessWidget {
  const MyHistoryQuotationPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  Widget build(BuildContext context) {
    return RepDocumentHistoryPage(
      title: 'Quotation history',
      documentType: 'quotation',
      icon: Icons.request_quote_rounded,
      accentColor: const Color(0xFF8B5CF6),
      emptyMessage: 'No quotations found for your account yet.',
      appBarLeading: appBarLeading,
    );
  }
}
