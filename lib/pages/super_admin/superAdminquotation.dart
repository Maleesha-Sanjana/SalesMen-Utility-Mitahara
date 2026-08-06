import 'package:flutter/material.dart';

import '../quotation_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminQuotationPage extends StatelessWidget {
  const SuperAdminQuotationPage({super.key});

  @override
  Widget build(BuildContext context) {
    return QuotationPage(appBarLeading: superAdminBackButton(context));
  }
}
