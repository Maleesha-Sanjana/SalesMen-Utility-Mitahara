import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/database_data_provider.dart';

class ReceiptPage extends StatefulWidget {
  const ReceiptPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<ReceiptPage> createState() => _ReceiptPageState();
}

class _ReceiptPageState extends State<ReceiptPage> {
  String? _selectedCustomerCode;
  final _amount = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final amount = double.tryParse(_amount.text.trim());
    if (_selectedCustomerCode == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a customer')));
      return;
    }
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid amount')),
      );
      return;
    }

    final provider = context.read<DatabaseDataProvider>();
    provider.addMockReceipt(
      customerCode: _selectedCustomerCode!,
      amount: amount,
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
    );

    // Clear fields after save
    _amount.clear();
    _note.clear();
    setState(() => _selectedCustomerCode = null);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Mock receipt saved successfully!'),
        action: SnackBarAction(label: 'OK', onPressed: () {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final database = context.watch<DatabaseDataProvider>();
    final customers = database.customers;

    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        title: const Text('Receipt'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Record customer payment (mock).'),
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
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amount,
                decoration: const InputDecoration(labelText: 'Amount'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _note,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
                maxLines: 2,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _save,
                child: const Text('Save Receipt (Mock)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
