import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../SalesAndhistory.dart';
import '../admin_current_sale_page.dart';
import '../admin_device_tracking_page.dart';
import '../admin_history/admin_history_crn_page.dart';
import '../admin_history/admin_history_invoice_page.dart';
import '../admin_history/admin_history_quotation_page.dart';
import '../admin_history/admin_history_sales_order_page.dart';
import '../admin_location_tracking_page.dart';
import '../admin_user_management_page.dart';
import '../admin/assign_customers_page.dart';
import '../crn.dart';
import '../customer_creation_page.dart';
import '../customer_location.dart';
import '../invoice_page.dart';
import '../leaderboard_page.dart';
import '../my_history/my_history_crn_page.dart';
import '../my_history/my_history_invoice_page.dart';
import '../my_history/my_history_location_page.dart';
import '../my_history/my_history_quotation_page.dart';
import '../my_history/my_history_sales_order_page.dart';
import '../my_sales_and_history_page.dart';
import '../quotation_page.dart';
import '../receipt_page.dart';
import '../sales_order_page.dart';
import '../salesmanWiseLocation.dart';
import '../stock_reports_page.dart';
import 'superAdminUserRights.dart';
import 'superAdminprofile.dart';
import 'super_admin_menu.dart';

class SuperAdminHomePage extends StatefulWidget {
  const SuperAdminHomePage({super.key});

  @override
  State<SuperAdminHomePage> createState() => _SuperAdminHomePageState();
}

class _SuperAdminHomePageState extends State<SuperAdminHomePage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  String _selectedRoute = '/super-admin/device-tracking';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      key: _scaffoldKey,
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Distribution - Super Admin',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Welcome, ${auth.salesmanName} (Super Admin)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.red.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    for (final tab in SuperAdminMenu.tabs) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
                        child: Text(
                          tab.title,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      ...tab.items.map((item) {
                        final isCurrent = item.route == _selectedRoute;
                        return ListTile(
                          leading: CircleAvatar(
                            radius: 18,
                            backgroundColor: item.color.withValues(alpha: 0.14),
                            child: Icon(item.icon, color: item.color, size: 20),
                          ),
                          title: Text(
                            item.title,
                            style: TextStyle(
                              fontWeight:
                                  isCurrent ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                          selected: isCurrent,
                          selectedTileColor: theme.colorScheme.primary
                              .withValues(alpha: 0.08),
                          onTap: () {
                            Navigator.of(context).pop();
                            if (isCurrent) return;
                            setState(() => _selectedRoute = item.route);
                          },
                        );
                      }),
                    ],
                  ],
                ),
              ),
              if (auth.salesmanCode.isNotEmpty) ...[
                const Divider(height: 1),
                ListTile(
                  leading: CircleAvatar(
                    radius: 18,
                    backgroundColor: theme.colorScheme.primary.withValues(
                      alpha: 0.12,
                    ),
                    child: Icon(
                      Icons.person_rounded,
                      color: theme.colorScheme.primary,
                      size: 20,
                    ),
                  ),
                  title: const Text(
                    'My Profile',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    auth.salesmanName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: _selectedRoute == SuperAdminMenu.profileRoute,
                  selectedTileColor: theme.colorScheme.primary.withValues(
                    alpha: 0.08,
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    setState(
                      () => _selectedRoute = SuperAdminMenu.profileRoute,
                    );
                  },
                ),
              ],
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout_rounded),
                title: const Text('Back to Login'),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (BuildContext context) {
                      return AlertDialog(
                        title: const Text('Logout'),
                        content: const Text('Are you sure you want to logout?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Cancel'),
                          ),
                          ElevatedButton(
                            onPressed: () async {
                              final navigator = Navigator.of(context);
                              navigator.pop();
                              await auth.logout();
                              navigator.pushNamedAndRemoveUntil('/', (route) => false);
                            },
                            child: const Text('Logout'),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
      body: _buildSelectedPage(),
    );
  }

  Widget _buildSelectedPage() {
    final menuButton = IconButton(
      icon: const Icon(Icons.menu_rounded),
      tooltip: 'Open super admin menu',
      onPressed: () => _scaffoldKey.currentState?.openDrawer(),
    );

    switch (_selectedRoute) {
      case '/super-admin/admin/location-tracking':
        return AdminLocationTrackingPage(appBarLeading: menuButton);
      case '/super-admin/admin/salesman-location-history':
        return SalesmanWiseLocationPage(appBarLeading: menuButton);
      case '/super-admin/admin/users':
        return AdminUserManagementPage(appBarLeading: menuButton);
      case '/admin/assign-customers':
        return AssignCustomersPage(appBarLeading: menuButton);
      case '/super-admin/user-rights':
      case '/super-admin/admin/use-rights':
        return SuperAdminUseRightsPage(appBarLeading: menuButton);
      case '/super-admin/admin/current-sale':
        return AdminCurrentSalePage(appBarLeading: menuButton);
      case '/super-admin/profile':
        return SuperAdminProfilePage(appBarLeading: menuButton);
      case '/super-admin/admin/sales-and-history':
        return SalesAndhistoryPage(
          appBarLeading: menuButton,
          superAdminMode: true,
        );
      case '/super-admin/admin/invoice':
        return AdminHistoryInvoicePage(appBarLeading: menuButton);
      case '/super-admin/admin/sales-order-history':
        return AdminHistorySalesOrderPage(appBarLeading: menuButton);
      case '/super-admin/admin/quotation-history':
        return AdminHistoryQuotationPage(appBarLeading: menuButton);
      case '/super-admin/admin/crn-history':
        return AdminHistoryCrnPage(appBarLeading: menuButton);
      case '/super-admin/admin/leaderboard':
        return LeaderboardPage(appBarLeading: menuButton);
      case '/super-admin/ref/sales-order':
        return SalesOrderPage(appBarLeading: menuButton);
      case '/super-admin/ref/invoice':
        return InvoiceSimplePage(appBarLeading: menuButton);
      case '/super-admin/ref/quotation':
        return QuotationPage(appBarLeading: menuButton);
      case '/super-admin/ref/crn':
        return CrnPage(appBarLeading: menuButton);
      case '/super-admin/ref/receipt':
        return ReceiptPage(appBarLeading: menuButton);
      case '/super-admin/ref/customer-create':
        return CustomerCreationPage(appBarLeading: menuButton);
      case '/super-admin/ref/customer-locations':
        return CustomerLocationPage(appBarLeading: menuButton);
      case '/super-admin/ref/my-sales':
        return MySalesAndHistoryPage(
          appBarLeading: menuButton,
          superAdminMode: true,
        );
      case '/super-admin/ref/history/invoice':
        return MyHistoryInvoicePage(appBarLeading: menuButton);
      case '/super-admin/ref/history/sales-order':
        return MyHistorySalesOrderPage(appBarLeading: menuButton);
      case '/super-admin/ref/history/quotation':
        return MyHistoryQuotationPage(appBarLeading: menuButton);
      case '/super-admin/ref/history/crn':
        return MyHistoryCrnPage(appBarLeading: menuButton);
      case '/super-admin/ref/history/location':
        return MyHistoryLocationPage(appBarLeading: menuButton);
      case '/super-admin/ref/leaderboard':
        return LeaderboardPage(appBarLeading: menuButton);
      case '/super-admin/ref/stock-reports':
        return StockReportsPage(appBarLeading: menuButton);
      case '/super-admin/device-tracking':
      default:
        return AdminDeviceTrackingPage(appBarLeading: menuButton);
    }
  }
}
