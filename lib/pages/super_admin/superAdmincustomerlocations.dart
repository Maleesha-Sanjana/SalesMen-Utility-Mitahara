import 'package:flutter/material.dart';

import '../customer_location.dart';
import 'super_admin_back_button.dart';

class SuperAdminCustomerLocationsPage extends StatelessWidget {
  const SuperAdminCustomerLocationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomerLocationPage(appBarLeading: superAdminBackButton(context));
  }
}
