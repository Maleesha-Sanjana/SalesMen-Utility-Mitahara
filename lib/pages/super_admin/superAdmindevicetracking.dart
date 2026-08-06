import 'package:flutter/material.dart';

import '../admin_device_tracking_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminDeviceTrackingPage extends StatelessWidget {
  const SuperAdminDeviceTrackingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminDeviceTrackingPage(
      appBarLeading: superAdminBackButton(context),
    );
  }
}
