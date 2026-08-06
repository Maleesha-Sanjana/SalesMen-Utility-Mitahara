import 'package:flutter/material.dart';

import '../SalesAndhistory.dart';
import 'super_admin_back_button.dart';

class SuperAdminSalesHistoryPage extends StatelessWidget {
  const SuperAdminSalesHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SalesAndhistoryPage(
      appBarLeading: superAdminBackButton(context),
      superAdminMode: true,
    );
  }
}
