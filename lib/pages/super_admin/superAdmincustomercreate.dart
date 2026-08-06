import 'package:flutter/material.dart';

import '../customer_creation_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminCustomerCreatePage extends StatelessWidget {
  const SuperAdminCustomerCreatePage({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomerCreationPage(appBarLeading: superAdminBackButton(context));
  }
}
