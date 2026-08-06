import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';
import '../services/offline_auto_sync_service.dart';
import '../services/offline_sync_service.dart';
import 'customer_creation_page.dart';
import 'customer_location.dart';
import 'invoice_page.dart';
import 'leaderboard_page.dart';
import 'my_sales_and_history_page.dart';
import 'quotation_page.dart';
import 'receipt_page.dart';
import 'crn.dart';
import 'sales_order_page.dart';
import 'salesman_profile_page.dart';
import 'stock_reports_page.dart';

class NormalUserHomePage extends StatefulWidget {
  const NormalUserHomePage({super.key});

  @override
  State<NormalUserHomePage> createState() => _NormalUserHomePageState();
}

class _NormalUserHomePageState extends State<NormalUserHomePage>
    with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final _autoSync = OfflineAutoSyncService.instance;
  String _selectedRoute = '/sales-order';
  bool _isDrawerOpen = false;
  bool _isSavingPlaceCheckIn = false;
  Map<String, bool> _useRights = const {};

  static const Map<String, String> _routeRightKeys = {
    '/sales-order': 'CanSalesOrder',
    '/invoices': 'CanInvoice',
    '/quotation': 'CanQuotation',
    '/sales-return': 'CanCRN',
    '/my-sales': 'CanMySalesHistory',
    '/customer-create': 'CanCustomerCreate',
    '/customer-locations': 'CanCustomerLocations',
    '/leaderboard': 'CanLeaderboard',
    '/stock-reports': 'CanStockReports',
    '/receipt': 'CanReceipts',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _autoSync.onSyncCompleted = _handleSyncCompleted;
    _autoSync.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadUseRights();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoSync.onSyncCompleted = null;
    _autoSync.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _autoSync.scheduleSyncAttempt();
    }
  }

  void _handleSyncCompleted(OfflineSyncAllResult result, bool manual) {
    if (!mounted) return;

    if (result.totalSynced > 0 && !manual) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Auto-synced ${result.totalSynced} queued item(s) to the server.',
          ),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    if (manual) {
      final message = result.totalSynced == 0 &&
              result.totalFailed == 0 &&
              result.totalRemaining == 0
          ? 'Nothing in the sync queue'
          : result.message ??
              'Sync complete: ${result.totalSynced} synced, '
                  '${result.totalFailed} failed, ${result.totalRemaining} remaining.';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: result.totalFailed > 0
              ? Colors.orange
              : (result.totalSynced > 0 ? Colors.green : null),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _syncAllPendingItems() async {
    await _autoSync.syncAll(manual: true);
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
      // Keep defaults from menu item enabled flags if rights cannot load.
    }
  }

  bool _isMenuItemEnabled(_NormalUserMenuItem item) {
    final rightKey = _routeRightKeys[item.route];
    if (rightKey != null && _useRights.containsKey(rightKey)) {
      return _useRights[rightKey] == true;
    }
    return item.enabled;
  }

  bool _isMenuItemEnabledByRoute(String route) {
    final match = _menuItems.where((item) => item.route == route);
    if (match.isEmpty) return true;
    return _isMenuItemEnabled(match.first);
  }

  Future<void> _markMyPlace() async {
    final auth = context.read<AuthProvider>();
    if (auth.salesmanCode.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Salesman information not available')),
      );
      return;
    }

    setState(() => _isSavingPlaceCheckIn = true);

    try {
      final capture = await LocationService.captureCurrentLocation();
      if (!capture.success || capture.position == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              capture.message ?? 'Unable to capture GPS for this place',
            ),
          ),
        );
        return;
      }

      final position = capture.position!;
      await LocationService.sendLocationToServer(
        auth.salesmanCode,
        auth.salesmanName,
        position,
        manualCheckIn: true,
      );

      if (!mounted) return;
      if (_isDrawerOpen) {
        Navigator.of(context).pop();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Location saved: ${position.latitude.toStringAsFixed(6)}, '
            '${position.longitude.toStringAsFixed(6)}',
          ),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst('Exception: ', ''),
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSavingPlaceCheckIn = false);
    }
  }

  static const List<_NormalUserMenuItem> _menuItems = [
    _NormalUserMenuItem(
      icon: Icons.shopping_cart_rounded,
      title: 'Sales Order',
      route: '/sales-order',
      color: Color(0xFF598DC9),
    ),
    _NormalUserMenuItem(
      icon: Icons.request_quote_rounded,
      title: 'Invoice',
      route: '/invoices',
      color: Color(0xFF10B981),
    ),
    _NormalUserMenuItem(
      icon: Icons.description_rounded,
      title: 'Quotation',
      route: '/quotation',
      color: Color(0xFF22C55E),
    ),
    _NormalUserMenuItem(
      icon: Icons.assignment_return_rounded,
      title: 'CRN',
      route: '/sales-return',
      color: Color(0xFFEF4444),
    ),
    _NormalUserMenuItem(
      icon: Icons.payments_rounded,
      title: 'My Sales & History',
      route: '/my-sales',
      color: Color(0xFF598DC9),
    ),
    _NormalUserMenuItem(
      icon: Icons.person_add_alt_1_rounded,
      title: 'Customer Registration',
      route: '/customer-create',
      color: Color(0xFFF59E0B),
    ),
    _NormalUserMenuItem(
      icon: Icons.map_rounded,
      title: 'Customer Locations',
      route: '/customer-locations',
      color: Color(0xFF0EA5E9),
    ),
    _NormalUserMenuItem(
      icon: Icons.leaderboard_rounded,
      title: 'LeaderBoard',
      route: '/leaderboard',
      color: Color(0xFFF59E0B),
    ),
    _NormalUserMenuItem(
      icon: Icons.bar_chart_rounded,
      title: 'Stock Reports',
      route: '/stock-reports',
      color: Color(0xFF0EA5E9),
      enabled: false,
    ),
    _NormalUserMenuItem(
      icon: Icons.receipt_long_rounded,
      title: 'Receipts',
      route: '/receipt',
      color: Color(0xFF598DC9),
      enabled: false,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      key: _scaffoldKey,
      onDrawerChanged: (isOpened) {
        setState(() => _isDrawerOpen = isOpened);
        if (isOpened) _autoSync.refreshPendingCount();
      },
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Distribution - Ref Portal',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Welcome, ${auth.salesmanName} (User)',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.7,
                              ),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    FloatingActionButton.small(
                      heroTag: 'rep_mark_place',
                      tooltip: 'Mark my place',
                      backgroundColor: const Color(0xFF598DC9),
                      foregroundColor: Colors.white,
                      onPressed:
                          _isSavingPlaceCheckIn ? null : _markMyPlace,
                      child: _isSavingPlaceCheckIn
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.add_location_alt_rounded),
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
                    final isCurrent = itemEnabled && item.route == _selectedRoute;
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
                          fontWeight: isCurrent
                              ? FontWeight.w700
                              : FontWeight.w500,
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
              const Divider(height: 1),
              ValueListenableBuilder<bool>(
                valueListenable: _autoSync.isSyncing,
                builder: (context, isSyncing, _) {
                  return ValueListenableBuilder<int>(
                    valueListenable: _autoSync.pendingCount,
                    builder: (context, pendingSyncCount, __) {
                      return ListTile(
                        enabled: !isSyncing,
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor: const Color(
                            0xFF598DC9,
                          ).withValues(alpha: 0.14),
                          child: isSyncing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.sync_rounded,
                                  color: Color(0xFF598DC9),
                                  size: 20,
                                ),
                        ),
                        title: const Text(
                          'Sync Queue',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          pendingSyncCount > 0
                              ? '$pendingSyncCount item(s) queued • auto-sync when online'
                              : 'All items are synced',
                        ),
                        trailing: pendingSyncCount > 0
                            ? CircleAvatar(
                                radius: 14,
                                backgroundColor: const Color(0xFF598DC9),
                                child: Text(
                                  '$pendingSyncCount',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              )
                            : null,
                        onTap: _syncAllPendingItems,
                      );
                    },
                  );
                },
              ),
              if (auth.salesmanCode.isNotEmpty)
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
                  selected: _selectedRoute == '/my-profile',
                  selectedTileColor: theme.colorScheme.primary.withValues(
                    alpha: 0.08,
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    setState(() => _selectedRoute = '/my-profile');
                  },
                ),
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
    final auth = context.read<AuthProvider>();
    final menuButton = IconButton(
      icon: const Icon(Icons.menu_rounded),
      tooltip: 'Open categories',
      onPressed: () => _scaffoldKey.currentState?.openDrawer(),
    );

    switch (_selectedRoute) {
      case '/invoices':
        return InvoiceSimplePage(appBarLeading: menuButton);
      case '/quotation':
        return QuotationPage(appBarLeading: menuButton);
      case '/sales-return':
        return CrnPage(appBarLeading: menuButton);
      case '/receipt':
        return ReceiptPage(appBarLeading: menuButton);
      case '/customer-create':
        return CustomerCreationPage(appBarLeading: menuButton);
      case '/customer-locations':
        return CustomerLocationPage(appBarLeading: menuButton);
      case '/leaderboard':
        return LeaderboardPage(appBarLeading: menuButton);
      case '/stock-reports':
        return StockReportsPage(appBarLeading: menuButton);
      case '/my-sales':
        return MySalesAndHistoryPage(appBarLeading: menuButton);
      case '/my-profile':
        return SalesmanProfilePage(
          appBarLeading: menuButton,
          salesmanCode: auth.salesmanCode,
        );
      case '/sales-order':
      default:
        return SalesOrderPage(appBarLeading: menuButton);
    }
  }
}

class _NormalUserMenuItem {
  const _NormalUserMenuItem({
    required this.icon,
    required this.title,
    required this.route,
    required this.color,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String route;
  final Color color;
  final bool enabled;
}
