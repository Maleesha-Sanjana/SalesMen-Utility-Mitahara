import 'package:flutter/material.dart';

class SuperAdminMenuItem {
  const SuperAdminMenuItem({
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

class SuperAdminMenuTab {
  const SuperAdminMenuTab({
    required this.title,
    required this.items,
  });

  final String title;
  final List<SuperAdminMenuItem> items;
}

class SuperAdminMenu {
  SuperAdminMenu._();

  static const profileRoute = '/super-admin/profile';

  static const List<SuperAdminMenuTab> tabs = [
    SuperAdminMenuTab(
      title: 'Super Admin',
      items: [
        SuperAdminMenuItem(
          icon: Icons.devices_rounded,
          title: 'Device Tracking',
          route: '/super-admin/device-tracking',
          color: Color(0xFF6366F1),
        ),
        SuperAdminMenuItem(
          icon: Icons.tune_rounded,
          title: 'User Rights',
          route: '/super-admin/user-rights',
          color: Color(0xFF7C3AED),
        ),

        SuperAdminMenuItem(
          icon: Icons.location_on_rounded,
          title: 'Location Tracking',
          route: '/super-admin/admin/location-tracking',
          color: Color(0xFF10B981),
        ),
        SuperAdminMenuItem(
          icon: Icons.route_rounded,
          title: 'Salesmans Location History',
          route: '/super-admin/admin/salesman-location-history',
          color: Color(0xFF7C3AED),
        ),
      ],
    ),
    SuperAdminMenuTab(
      title: 'Admin',
      items: [
        SuperAdminMenuItem(
          icon: Icons.assignment_ind_rounded,
          title: 'Assign Customers',
          route: '/admin/assign-customers',
          color: Color(0xFF4F46E5),
        ),
        SuperAdminMenuItem(
          icon: Icons.person_add_alt_1_rounded,
          title: 'User Creation',
          route: '/super-admin/admin/users',
          color: Color(0xFF8B5CF6),
        ),
        SuperAdminMenuItem(
          icon: Icons.point_of_sale_rounded,
          title: 'Current Sale',
          route: '/super-admin/admin/current-sale',
          color: Color(0xFF598DC9),
        ),
        SuperAdminMenuItem(
          icon: Icons.history_rounded,
          title: 'Sales & History',
          route: '/super-admin/admin/sales-and-history',
          color: Color(0xFF0D9488),
        ),
        SuperAdminMenuItem(
          icon: Icons.receipt_long_rounded,
          title: 'Invoice Report',
          route: '/super-admin/admin/invoice',
          color: Color(0xFF10B981),
        ),
        SuperAdminMenuItem(
          icon: Icons.shopping_cart_checkout_rounded,
          title: 'Sales Order Report',
          route: '/super-admin/admin/sales-order-history',
          color: Color(0xFF598DC9),
        ),
        SuperAdminMenuItem(
          icon: Icons.request_quote_rounded,
          title: 'Quotation Report',
          route: '/super-admin/admin/quotation-history',
          color: Color(0xFF8B5CF6),
        ),
        SuperAdminMenuItem(
          icon: Icons.assignment_return_rounded,
          title: 'CRN Report',
          route: '/super-admin/admin/crn-history',
          color: Color(0xFFEF4444),
        ),
        SuperAdminMenuItem(
          icon: Icons.leaderboard_rounded,
          title: 'LeaderBoard',
          route: '/super-admin/admin/leaderboard',
          color: Color(0xFFF59E0B),
        ),
      ],
    ),
    SuperAdminMenuTab(
      title: 'Sales Rep',
      items: [
        SuperAdminMenuItem(
          icon: Icons.shopping_cart_rounded,
          title: 'Sales Order',
          route: '/super-admin/ref/sales-order',
          color: Color(0xFF598DC9),
        ),
        SuperAdminMenuItem(
          icon: Icons.request_quote_rounded,
          title: 'Invoice',
          route: '/super-admin/ref/invoice',
          color: Color(0xFF10B981),
        ),
        SuperAdminMenuItem(
          icon: Icons.description_rounded,
          title: 'Quotation',
          route: '/super-admin/ref/quotation',
          color: Color(0xFF22C55E),
        ),
        SuperAdminMenuItem(
          icon: Icons.assignment_return_rounded,
          title: 'CRN',
          route: '/super-admin/ref/crn',
          color: Color(0xFFEF4444),
        ),
        SuperAdminMenuItem(
          icon: Icons.receipt_long_rounded,
          title: 'Receipts',
          route: '/super-admin/ref/receipt',
          color: Color(0xFF598DC9),
        ),
        SuperAdminMenuItem(
          icon: Icons.person_add_alt_1_rounded,
          title: 'Customer Registration',
          route: '/super-admin/ref/customer-create',
          color: Color(0xFFF59E0B),
        ),
        SuperAdminMenuItem(
          icon: Icons.map_rounded,
          title: 'Customer Locations',
          route: '/super-admin/ref/customer-locations',
          color: Color(0xFF0EA5E9),
        ),
        SuperAdminMenuItem(
          icon: Icons.location_on_rounded,
          title: 'My Location History',
          route: '/super-admin/ref/history/location',
          color: Color(0xFF0D9488),
        ),
        SuperAdminMenuItem(
          icon: Icons.leaderboard_rounded,
          title: 'LeaderBoard',
          route: '/super-admin/ref/leaderboard',
          color: Color(0xFFF59E0B),
        ),
        SuperAdminMenuItem(
          icon: Icons.bar_chart_rounded,
          title: 'Stock Reports',
          route: '/super-admin/ref/stock-reports',
          color: Color(0xFF0EA5E9),
        ),
      ],
    ),
  ];
}
