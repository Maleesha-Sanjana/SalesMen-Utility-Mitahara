import 'package:flutter/material.dart';

import '../admin_history/admin_history_quotation_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminQuotationReportPage extends StatelessWidget {
  const SuperAdminQuotationReportPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminHistoryQuotationPage(
      appBarLeading: superAdminBackButton(context),
    );
  }
}
