import 'package:flutter/material.dart';

import 'admin_document_history_page.dart';

class AdminHistoryCrnPage extends StatelessWidget {
  const AdminHistoryCrnPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  Widget build(BuildContext context) {
    return AdminDocumentHistoryPage(
      title: 'CRN history report',
      documentType: 'crn',
      icon: Icons.assignment_return_rounded,
      accentColor: const Color(0xFFEF4444),
      emptyMessage: 'No CRNs found for the selected filters.',
      appBarLeading: appBarLeading,
    );
  }
}
