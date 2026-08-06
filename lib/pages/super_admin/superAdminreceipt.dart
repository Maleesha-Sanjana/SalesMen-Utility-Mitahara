import 'package:flutter/material.dart';

import '../receipt_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminReceiptPage extends StatelessWidget {
  const SuperAdminReceiptPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ReceiptPage(appBarLeading: superAdminBackButton(context));
  }
}
