import 'package:flutter/material.dart';

import 'admin_document_history_page.dart';

class AdminHistorySalesOrderPage extends StatelessWidget {
  const AdminHistorySalesOrderPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  Widget build(BuildContext context) {
    return AdminDocumentHistoryPage(
      title: 'Sales order history report',
      documentType: 'sales-order',
      icon: Icons.shopping_cart_checkout_rounded,
      accentColor: const Color(0xFF598DC9),
      emptyMessage: 'No sales orders found for the selected filters.',
      appBarLeading: appBarLeading,
    );
  }
}
