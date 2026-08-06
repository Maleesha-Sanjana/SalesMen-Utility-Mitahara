import 'package:flutter/material.dart';

import '../my_history/my_history_invoice_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminMyInvoiceHistoryPage extends StatelessWidget {
  const SuperAdminMyInvoiceHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MyHistoryInvoicePage(appBarLeading: superAdminBackButton(context));
  }
}
