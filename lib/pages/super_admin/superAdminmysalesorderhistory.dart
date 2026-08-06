import 'package:flutter/material.dart';

import '../my_history/my_history_sales_order_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminMySalesOrderHistoryPage extends StatelessWidget {
  const SuperAdminMySalesOrderHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MyHistorySalesOrderPage(
      appBarLeading: superAdminBackButton(context),
    );
  }
}
