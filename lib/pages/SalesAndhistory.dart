import 'package:flutter/material.dart';

class SalesAndhistoryPage extends StatelessWidget {
  const SalesAndhistoryPage({super.key, this.appBarLeading, this.superAdminMode = false});

  final Widget? appBarLeading;
  final bool superAdminMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget buildCard({
      required IconData icon,
      required String title,
      String? subtitle,
      required VoidCallback onTap,
      Color color = const Color(0xFF598DC9),
    }) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.black12),
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 8,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: color.withValues(alpha: 0.15),
                  child: Icon(icon, color: color, size: 24),
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    letterSpacing: 0.2,
                    color: theme.colorScheme.onSurface,
                    height: 1.2,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black54,
                      height: 1.2,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    final cards = [
      (
        icon: Icons.receipt_long_rounded,
        title: 'Invoice history',
        subtitle: 'Salesman-wise invoice report',
        route: superAdminMode
            ? '/super-admin/admin/invoice'
            : '/admin-history/invoices',
        color: const Color(0xFF10B981),
      ),
      (
        icon: Icons.shopping_cart_checkout_rounded,
        title: 'Sales order history',
        subtitle: 'Salesman-wise sales order report',
        route: superAdminMode
            ? '/super-admin/admin/sales-order-history'
            : '/admin-history/sales-orders',
        color: const Color(0xFF598DC9),
      ),
      (
        icon: Icons.request_quote_rounded,
        title: 'Quotation history',
        subtitle: 'Salesman-wise quotation report',
        route: superAdminMode
            ? '/super-admin/admin/quotation-history'
            : '/admin-history/quotations',
        color: const Color(0xFF8B5CF6),
      ),
      (
        icon: Icons.assignment_return_rounded,
        title: 'CRN history',
        subtitle: 'Salesman-wise CRN report',
        route: superAdminMode
            ? '/super-admin/admin/crn-history'
            : '/admin-history/crn',
        color: const Color(0xFFEF4444),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        leading:
            appBarLeading ??
            IconButton(
              icon: const Icon(Icons.arrow_back),
              color: theme.colorScheme.onSurface,
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).pop(),
            ),
        title: const Text('Sales & History'),
        backgroundColor: const Color(0xFF0D9488).withValues(alpha: 0.08),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final crossAxisCount = width >= 1100
                ? 3
                : width >= 800
                ? 3
                : 2;
            final spacing = 16.0;
            final cellWidth =
                (width - spacing * (crossAxisCount - 1)) / crossAxisCount;
            final targetCellHeight = crossAxisCount == 2 ? 156.0 : 140.0;
            final aspect = cellWidth / targetCellHeight;

            return GridView.builder(
              padding: const EdgeInsets.only(bottom: 20),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: aspect,
              ),
              itemCount: cards.length,
              itemBuilder: (context, index) {
                final card = cards[index];
                return buildCard(
                  icon: card.icon,
                  title: card.title,
                  subtitle: card.subtitle,
                  onTap: () => Navigator.of(context).pushNamed(card.route),
                  color: card.color,
                );
              },
            );
          },
        ),
      ),
    );
  }
}
