import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class AdminCurrentSalePage extends StatefulWidget {
  const AdminCurrentSalePage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<AdminCurrentSalePage> createState() => _AdminCurrentSalePageState();
}

class _AdminCurrentSalePageState extends State<AdminCurrentSalePage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();

    // Check if user is admin
    if (!auth.isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Access Denied')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.block, size: 64, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                'Access Denied',
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'You need administrator privileges to access this page.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        automaticallyImplyLeading: widget.appBarLeading == null,
        title: const Text('Current Sale'),
        backgroundColor: Colors.blue.withValues(alpha: 0.1),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.admin_panel_settings, size: 16, color: Colors.red),
                const SizedBox(width: 4),
                Text(
                  'ADMIN ONLY',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Current sale features section
            Text(
              'Current Sale Features',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),

            // Feature cards
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 0.86,
                children: [
                  _buildSaleFeatureCard(
                    context,
                    icon: Icons.trending_up,
                    title: 'Live Sales',
                    description: 'Monitor ongoing sales in real-time',
                    color: Colors.green,
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Live sales monitoring activated - Admin access confirmed!',
                          ),
                          backgroundColor: Colors.green,
                        ),
                      );
                    },
                  ),
                  _buildSaleFeatureCard(
                    context,
                    icon: Icons.receipt,
                    title: 'Active Transactions',
                    description: 'View all active transactions',
                    color: Colors.orange,
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Active transactions loaded - Admin access confirmed!',
                          ),
                          backgroundColor: Colors.green,
                        ),
                      );
                    },
                  ),
                  _buildSaleFeatureCard(
                    context,
                    icon: Icons.dashboard,
                    title: 'Sales Dashboard',
                    description: 'Comprehensive sales overview',
                    color: Colors.purple,
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Sales dashboard opened - Admin access confirmed!',
                          ),
                          backgroundColor: Colors.green,
                        ),
                      );
                    },
                  ),
                  _buildSaleFeatureCard(
                    context,
                    icon: Icons.payment,
                    title: 'Payment Status',
                    description: 'Monitor payment processing',
                    color: Colors.teal,
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Payment status checked - Admin access confirmed!',
                          ),
                          backgroundColor: Colors.green,
                        ),
                      );
                    },
                  ),
                  _buildSaleFeatureCard(
                    context,
                    icon: Icons.inventory,
                    title: 'Stock Movement',
                    description: 'Track inventory changes',
                    color: Colors.indigo,
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Stock movement tracked - Admin access confirmed!',
                          ),
                          backgroundColor: Colors.green,
                        ),
                      );
                    },
                  ),
                  _buildSaleFeatureCard(
                    context,
                    icon: Icons.person,
                    title: 'Customer Activity',
                    description: 'Monitor customer interactions',
                    color: Colors.brown,
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Customer activity monitored - Admin access confirmed!',
                          ),
                          backgroundColor: Colors.green,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaleFeatureCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
    required Color color,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);

    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: color.withValues(alpha: 0.1),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
