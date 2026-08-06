import 'package:flutter/material.dart';

import '../my_history/my_history_crn_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminMyCrnHistoryPage extends StatelessWidget {
  const SuperAdminMyCrnHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MyHistoryCrnPage(appBarLeading: superAdminBackButton(context));
  }
}
