import 'package:flutter/material.dart';

import '../admin_location_tracking_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminLocationTrackingPage extends StatelessWidget {
  const SuperAdminLocationTrackingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminLocationTrackingPage(
      appBarLeading: superAdminBackButton(context),
    );
  }
}
