import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import 'adminProfile.dart';
import 'admin_current_sale_page.dart';
import 'admin_location_tracking_page.dart';
import 'admin_user_management_page.dart';
import 'super_admin/superAdminUserRights.dart';
import 'SalesAndhistory.dart';
import 'crn.dart';
import 'invoice_page.dart';
import 'leaderboard_page.dart';
import 'admin/assign_customers_page.dart';
import 'salesmanWiseLocation.dart';

class AdminHomePage extends StatefulWidget {
  const AdminHomePage({super.key});

  @override
  State<AdminHomePage> createState() => _AdminHomePageState();
}

class _AdminHomePageState extends State<AdminHomePage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  String _selectedRoute = '/admin/salesman-location-history';
  Map<String, bool> _useRights = const {};

  static const Map<String, String> _routeRightKeys = {
    '/admin/salesman-location-history': 'CanAdminSalesmanLocationHistory',
    '/admin/users': 'CanAdminUserCreation',
    '/admin/user-rights': 'CanAdminUserCreation',
    '/admin/sales-and-history': 'CanAdminSalesAndHistory',
    '/admin/invoice': 'CanInvoice',
    '/admin/crn': 'CanCRN',
    '/admin/leaderboard': 'CanLeaderboard',
    '/admin/location-tracking': 'CanAdminLocationTracking',
    '/admin/current-sale': 'CanAdminCurrentSale',
  };

  static const List<_AdminMenuItem> _menuItems = [
    _AdminMenuItem(
      icon: Icons.route_rounded,
      title: 'Salesmans Location History',
      route: '/admin/salesman-location-history',
      color: Color(0xFF7C3AED),
    ),
    _AdminMenuItem(
      icon: Icons.person_add_alt_1_rounded,
      title: 'User Creation',
      route: '/admin/users',
      color: Color(0xFF8B5CF6),
    ),
    _AdminMenuItem(
      icon: Icons.admin_panel_settings_rounded,
      title: 'User Rights',
      route: '/admin/user-rights',
      color: Color(0xFF6D28D9),
    ),
    _AdminMenuItem(
      icon: Icons.assignment_ind_rounded,
      title: 'Assign Customers',
      route: '/admin/assign-customers',
      color: Color(0xFF4F46E5),
    ),
    _AdminMenuItem(
      icon: Icons.history_rounded,
      title: 'Sales & History',
      route: '/admin/sales-and-history',
      color: Color(0xFF0D9488),
    ),
    _AdminMenuItem(
      icon: Icons.request_quote_rounded,
      title: 'Invoice',
      route: '/admin/invoice',
      color: Color(0xFF10B981),
    ),
    _AdminMenuItem(
      icon: Icons.assignment_return_rounded,
      title: 'CRN',
      route: '/admin/crn',
      color: Color(0xFFEF4444),
    ),
    _AdminMenuItem(
      icon: Icons.leaderboard_rounded,
      title: 'LeaderBoard',
      route: '/admin/leaderboard',
      color: Color(0xFFF59E0B),
    ),
    _AdminMenuItem(
      icon: Icons.location_on_rounded,
      title: 'Location Tracking',
      route: '/admin/location-tracking',
      color: Color(0xFF10B981),
    ),
    _AdminMenuItem(
      icon: Icons.point_of_sale_rounded,
      title: 'Current Sale',
      route: '/admin/current-sale',
      color: Color(0xFF598DC9),
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadUseRights();
    });
  }

  Future<void> _loadUseRights() async {
    final auth = context.read<AuthProvider>();
    final code = auth.salesmanCode.trim();
    if (code.isEmpty) return;

    try {
      final rights = await ApiService.getSalesmanUseRights(code);
      if (!mounted) return;
      setState(() {
        _useRights = {
          for (final entry in rights.entries)
            entry.key: entry.value == true || entry.value == 1,
        };
        if (!_isMenuItemEnabledByRoute(_selectedRoute)) {
          final firstAllowed = _menuItems
              .where(_isMenuItemEnabled)
              .map((item) => item.route)
              .toList();
          if (firstAllowed.isNotEmpty) {
            _selectedRoute = firstAllowed.first;
          }
        }
      });
    } catch (_) {
      // Keep all sections enabled if rights cannot load.
    }
  }

  bool _isMenuItemEnabled(_AdminMenuItem item) {
    final rightKey = _routeRightKeys[item.route];
    if (rightKey != null && _useRights.containsKey(rightKey)) {
      return _useRights[rightKey] == true;
    }
    return true;
  }

  bool _isMenuItemEnabledByRoute(String route) {
    final match = _menuItems.where((item) => item.route == route);
    if (match.isEmpty) return true;
    return _isMenuItemEnabled(match.first);
  }

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
                      'Distribution - Admin Portal',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Welcome, ${auth.salesmanName} (Admin)',
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
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _menuItems.length,
                  itemBuilder: (context, index) {
                    final item = _menuItems[index];
                    final itemEnabled = _isMenuItemEnabled(item);
                    final isCurrent =
                        itemEnabled && item.route == _selectedRoute;
                    final itemColor = itemEnabled
                        ? item.color
                        : theme.colorScheme.onSurface.withValues(alpha: 0.38);

                    return ListTile(
                      enabled: itemEnabled,
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundColor: itemColor.withValues(alpha: 0.14),
                        child: Icon(item.icon, color: itemColor, size: 20),
                      ),
                      title: Text(
                        item.title,
                        style: TextStyle(
                          fontWeight:
                              isCurrent ? FontWeight.w700 : FontWeight.w500,
                          color: itemEnabled
                              ? null
                              : theme.colorScheme.onSurface.withValues(
                                  alpha: 0.38,
                                ),
                        ),
                      ),
                      selected: isCurrent,
                      selectedTileColor: theme.colorScheme.primary.withValues(
                        alpha: 0.08,
                      ),
                      onTap: itemEnabled
                          ? () {
                              Navigator.of(context).pop();
                              if (isCurrent) return;
                              setState(() => _selectedRoute = item.route);
                            }
                          : null,
                    );
                  },
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
                  selected: _selectedRoute == '/admin/profile',
                  selectedTileColor: theme.colorScheme.primary.withValues(
                    alpha: 0.08,
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    setState(() => _selectedRoute = '/admin/profile');
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
      tooltip: 'Open admin menu',
      onPressed: () => _scaffoldKey.currentState?.openDrawer(),
    );

    if (!_isMenuItemEnabledByRoute(_selectedRoute) &&
        _selectedRoute != '/admin/profile') {
      return Scaffold(
        appBar: AppBar(
          leading: menuButton,
          title: const Text('Access restricted'),
        ),
        body: const Center(
          child: Text('This section is disabled for your account.'),
        ),
      );
    }

    switch (_selectedRoute) {
      case '/admin/current-sale':
        return AdminCurrentSalePage(appBarLeading: menuButton);
      case '/admin/users':
        return AdminUserManagementPage(appBarLeading: menuButton);
      case '/admin/user-rights':
        return SuperAdminUseRightsPage(appBarLeading: menuButton);
      case '/admin/profile':
        return AdminProfilePage(appBarLeading: menuButton);
      case '/admin/sales-and-history':
        return SalesAndhistoryPage(appBarLeading: menuButton);
      case '/admin/invoice':
        return InvoiceSimplePage(appBarLeading: menuButton);
      case '/admin/crn':
        return CrnPage(appBarLeading: menuButton);
      case '/admin/leaderboard':
        return LeaderboardPage(appBarLeading: menuButton);
      case '/admin/location-tracking':
        return AdminLocationTrackingPage(appBarLeading: menuButton);
      case '/admin/assign-customers':
        return AssignCustomersPage(appBarLeading: menuButton);
      case '/admin/salesman-location-history':
      default:
        return SalesmanWiseLocationPage(appBarLeading: menuButton);
    }
  }
}

class _AdminMenuItem {
  const _AdminMenuItem({
    required this.icon,
    required this.title,
    required this.route,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String route;
  final Color color;
}
