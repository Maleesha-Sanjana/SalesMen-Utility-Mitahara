import 'package:flutter/material.dart';

import '../admin_user_management_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminUserCreationPage extends StatelessWidget {
  const SuperAdminUserCreationPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminUserManagementPage(appBarLeading: superAdminBackButton(context));
  }
}
