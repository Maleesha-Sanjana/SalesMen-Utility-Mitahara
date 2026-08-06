import 'package:flutter/material.dart';

import 'rep_document_history_page.dart';

class MyHistorySalesOrderPage extends StatelessWidget {
  const MyHistorySalesOrderPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  Widget build(BuildContext context) {
    return RepDocumentHistoryPage(
      title: 'Sales order history',
      documentType: 'sales-order',
      icon: Icons.shopping_cart_checkout_rounded,
      accentColor: const Color(0xFF598DC9),
      emptyMessage: 'No sales orders found for your account yet.',
      appBarLeading: appBarLeading,
    );
  }
}
