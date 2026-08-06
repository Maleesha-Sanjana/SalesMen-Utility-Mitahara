import 'package:flutter/material.dart';

import '../admin_history/admin_history_invoice_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminInvoiceReportPage extends StatelessWidget {
  const SuperAdminInvoiceReportPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminHistoryInvoicePage(
      appBarLeading: superAdminBackButton(context),
    );
  }
}
