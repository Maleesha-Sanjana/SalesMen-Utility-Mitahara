import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/cart_provider.dart';
import '../services/api_service.dart';

class CustomerSelectDialog {
  static Future<void> show(BuildContext context) async {
    final theme = Theme.of(context);
    final cart = context.read<CartProvider>();
    final auth = context.read<AuthProvider>();

    final TextEditingController searchController = TextEditingController();
    // Load customers from ERP
    List<Map<String, String>> allCustomers = [];
    try {
      final data = await ApiService.getCustomers(salesRepCode: '');
      allCustomers = data
          .map((c) => {
                'code': c['code']?.toString() ?? '',
                'name': c['name']?.toString() ?? '',
                'phone': c['phone']?.toString() ?? '',
              })
          .toList();
    } catch (e) {
      allCustomers = [];
    }
    List<Map<String, String>> filtered = List.from(allCustomers);

    void applyFilter(String q) {
      q = q.toLowerCase();
      filtered = allCustomers.where((c) {
        return c['name']!.toLowerCase().contains(q) ||
            (c['code']!).toLowerCase().contains(q) ||
            (c['phone']!).toLowerCase().contains(q);
      }).toList();
    }

    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(Icons.person_search_rounded, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  const Text('Select Customer'),
                ],
              ),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: searchController,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Search by name, code, phone',
                      ),
                      onChanged: (q) {
                        setState(() {
                          applyFilter(q);
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: Material(
                        color: Colors.transparent,
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final c = filtered[index];
                            return ListTile(
                              dense: true,
                              leading: CircleAvatar(
                                backgroundColor: theme.colorScheme.primary.withOpacity(0.1),
                                child: Text(c['name']!.substring(0, 1).toUpperCase(),
                                    style: TextStyle(color: theme.colorScheme.primary)),
                              ),
                              title: Text(c['name']!),
                              subtitle: Text('${c['code']} • ${c['phone']}'),
                              onTap: () {
                                cart.setCustomerInfo(name: c['name']);
                                Navigator.of(context).pop();
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
