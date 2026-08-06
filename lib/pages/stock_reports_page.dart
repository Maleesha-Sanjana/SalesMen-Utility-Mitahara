import 'package:flutter/material.dart';

class StockReportsPage extends StatefulWidget {
  const StockReportsPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<StockReportsPage> createState() => _StockReportsPageState();
}

class _StockReportsPageState extends State<StockReportsPage> {
  DateTimeRange? _range;
  final _searchController = TextEditingController();
  final List<Map<String, dynamic>> _items = [
    {'name': 'Item A', 'qty': 25},
    {'name': 'Item B', 'qty': 0},
    {'name': 'Item C', 'qty': 7},
    {'name': 'Item D', 'qty': 120},
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        title: const Text('Stock Reports'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          children: [
            _CategoryTile(
              icon: Icons.inventory_2_rounded,
              title: 'My Stock',
              color: const Color(0xFF10B981),
              onTap: () => Navigator.of(context).pushNamed('/my-stock'),
            ),
            _CategoryTile(
              icon: Icons.location_city_rounded,
              title: 'Location Wise Stock',
              color: const Color(0xFF0EA5E9),
              onTap: () => Navigator.of(context).pushNamed('/location-stock'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback onTap;

  const _CategoryTile({
    required this.icon,
    required this.title,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
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
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                backgroundColor: color.withOpacity(0.15),
                radius: 28,
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
