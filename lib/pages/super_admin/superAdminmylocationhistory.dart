import 'package:flutter/material.dart';

import '../my_history/my_history_location_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminMyLocationHistoryPage extends StatelessWidget {
  const SuperAdminMyLocationHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MyHistoryLocationPage(appBarLeading: superAdminBackButton(context));
  }
}
