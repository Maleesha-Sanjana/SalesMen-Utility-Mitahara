import 'package:flutter/material.dart';

import '../my_history/my_history_quotation_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminMyQuotationHistoryPage extends StatelessWidget {
  const SuperAdminMyQuotationHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MyHistoryQuotationPage(
      appBarLeading: superAdminBackButton(context),
    );
  }
}
