import 'package:flutter/material.dart';

import '../stock_reports_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminStockReportsPage extends StatelessWidget {
  const SuperAdminStockReportsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return StockReportsPage(appBarLeading: superAdminBackButton(context));
  }
}
