import 'package:flutter/material.dart';

import '../salesmanWiseLocation.dart';
import 'super_admin_back_button.dart';

class SuperAdminSalesmanLocationPage extends StatelessWidget {
  const SuperAdminSalesmanLocationPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SalesmanWiseLocationPage(appBarLeading: superAdminBackButton(context));
  }
}
