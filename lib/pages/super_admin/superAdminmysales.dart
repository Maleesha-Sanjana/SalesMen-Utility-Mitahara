import 'package:flutter/material.dart';

import '../my_sales_and_history_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminMySalesPage extends StatelessWidget {
  const SuperAdminMySalesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MySalesAndHistoryPage(
      appBarLeading: superAdminBackButton(context),
      superAdminMode: true,
    );
  }
}
