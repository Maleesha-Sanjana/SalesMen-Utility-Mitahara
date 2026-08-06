import 'package:flutter/material.dart';

import '../admin_history/admin_history_sales_order_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminSalesOrderReportPage extends StatelessWidget {
  const SuperAdminSalesOrderReportPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminHistorySalesOrderPage(
      appBarLeading: superAdminBackButton(context),
    );
  }
}
