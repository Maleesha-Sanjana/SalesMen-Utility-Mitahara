import 'package:flutter/material.dart';

import '../invoice_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminInvoicePage extends StatelessWidget {
  const SuperAdminInvoicePage({super.key});

  @override
  Widget build(BuildContext context) {
    return InvoiceSimplePage(appBarLeading: superAdminBackButton(context));
  }
}
