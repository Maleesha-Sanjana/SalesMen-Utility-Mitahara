import 'package:flutter/material.dart';

import '../admin_current_sale_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminCurrentSalePage extends StatelessWidget {
  const SuperAdminCurrentSalePage({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminCurrentSalePage(appBarLeading: superAdminBackButton(context));
  }
}
