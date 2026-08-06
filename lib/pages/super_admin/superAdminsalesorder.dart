import 'package:flutter/material.dart';

import '../sales_order_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminSalesOrderPage extends StatelessWidget {
  const SuperAdminSalesOrderPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SalesOrderPage(appBarLeading: superAdminBackButton(context));
  }
}
