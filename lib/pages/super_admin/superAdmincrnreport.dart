import 'package:flutter/material.dart';

import '../admin_history/admin_history_crn_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminCrnReportPage extends StatelessWidget {
  const SuperAdminCrnReportPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminHistoryCrnPage(appBarLeading: superAdminBackButton(context));
  }
}
