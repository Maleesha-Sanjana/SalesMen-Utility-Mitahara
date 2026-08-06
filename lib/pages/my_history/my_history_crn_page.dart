import 'package:flutter/material.dart';

import 'rep_document_history_page.dart';

class MyHistoryCrnPage extends StatelessWidget {
  const MyHistoryCrnPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  Widget build(BuildContext context) {
    return RepDocumentHistoryPage(
      title: 'CRN history',
      documentType: 'crn',
      icon: Icons.assignment_return_rounded,
      accentColor: const Color(0xFFEF4444),
      emptyMessage: 'No CRNs found for your account yet.',
      appBarLeading: appBarLeading,
    );
  }
}
