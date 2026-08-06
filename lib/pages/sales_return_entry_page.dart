import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/database_data_provider.dart';

class CrnEntryPage extends StatefulWidget {
  const CrnEntryPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<CrnEntryPage> createState() => _CrnEntryPageState();
}

class _CrnEntryPageState extends State<CrnEntryPage> {
  String? _selectedCustomerCode;
  Map<String, dynamic>? _selectedItem;
  final _qty = TextEditingController(text: '1');
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Load mock data when page initializes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('Loading mock data for CRN page');
      context.read<DatabaseDataProvider>().loadMockData();
    });
  }

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    debugPrint('Selected customer: $_selectedCustomerCode');
    debugPrint('Selected item: ${_selectedItem?['code']}');
    final qty = int.tryParse(_qty.text.trim());
    if (_selectedCustomerCode == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a customer')));
      return;
    }
    if (_selectedItem == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select an item')));
      return;
    }
    if (qty == null || qty <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid quantity')),
      );
      return;
    }

    final provider = context.read<DatabaseDataProvider>();
    provider.addMockReturn(
      customerCode: _selectedCustomerCode!,
      items: [
        {
          'productCode': _selectedItem!['code'] ?? '',
          'name': _selectedItem!['name'] ?? '',
          'qty': qty,
        },
      ],
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
    );

    // Clear fields after save
    _qty.text = '1';
    _note.clear();
    setState(() {
      _selectedCustomerCode = null;
      _selectedItem = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('CRN saved successfully!'),
        action: SnackBarAction(label: 'OK', onPressed: () {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final database = context.watch<DatabaseDataProvider>();
    debugPrint('CRN Page - Customer count: ${database.customers.length}');
    final customers = database.customers;
    // Mock products list for CRN page
    final products = <Map<String, dynamic>>[
      {'code': 'P001', 'name': 'Product 1'},
      {'code': 'P002', 'name': 'Product 2'},
      {'code': 'P003', 'name': 'Product 3'},
    ];

    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        title: const Text('Create CRN'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Create a Customer Return Note'),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Customer'),
                value: _selectedCustomerCode,
                items: customers
                    .map(
                      (c) => DropdownMenuItem(
                        value: c.code,
                        child: Text('${c.name} (${c.code})'),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _selectedCustomerCode = v),
                isExpanded: true,
                icon: const Icon(Icons.arrow_drop_down),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<Map<String, dynamic>>(
                decoration: const InputDecoration(labelText: 'Item'),
                value: _selectedItem,
                items: products
                    .map(
                      (p) => DropdownMenuItem(
                        value: p,
                        child: Text('${p['name']} (${p['code']})'),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _selectedItem = v),
                isExpanded: true,
                icon: const Icon(Icons.arrow_drop_down),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _qty,
                decoration: const InputDecoration(labelText: 'Quantity'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _note,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
                maxLines: 2,
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: _save, child: const Text('Save CRN')),
            ],
          ),
        ),
      ),
    );
  }
}
