import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../models/salesman.dart';

class AssignCustomersPage extends StatefulWidget {
  final Widget? appBarLeading;
  const AssignCustomersPage({Key? key, this.appBarLeading}) : super(key: key);

  @override
  _AssignCustomersPageState createState() => _AssignCustomersPageState();
}

class _AssignCustomersPageState extends State<AssignCustomersPage> {
  bool _isLoading = true;
  bool _isSaving = false;
  
  List<Salesman> _salesmen = [];
  Salesman? _selectedSalesman;
  String _salesmanSearchQuery = '';
  
  List<Map<String, dynamic>> _allCustomers = [];
  List<Map<String, dynamic>> _filteredCustomers = [];
  
  Set<String> _assignedCustomerCodes = {};

  @override
  void initState() {
    super.initState();
    _fetchInitialData();
  }

  Future<void> _fetchInitialData() async {
    setState(() => _isLoading = true);
    try {
      final salesmen = await ApiService.getSalesmen();
      final customers = await ApiService.getCustomers();
      
      setState(() {
        _salesmen = salesmen.where((s) => s.isActive).toList();
        _allCustomers = customers;
        _filteredCustomers = _allCustomers;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading data: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _onSalesmanSelected(Salesman? salesman) {
    setState(() {
      _selectedSalesman = salesman;
      _salesmanSearchQuery = '';
      _assignedCustomerCodes.clear();
      
      if (salesman != null) {
        final salesmanCode = salesman.salesmanCode;
        for (var customer in _allCustomers) {
          if (customer['assigned'] == salesmanCode) {
            _assignedCustomerCodes.add(customer['code'].toString());
          }
        }
      }
    });
  }

  List<Salesman> get _filteredSalesmen {
    if (_salesmanSearchQuery.isEmpty) return _salesmen;
    final q = _salesmanSearchQuery.toLowerCase();
    return _salesmen.where((s) {
      return (s.salesmanName ?? '').toLowerCase().contains(q) || 
             s.salesmanCode.toLowerCase().contains(q);
    }).toList();
  }

  void _filterCustomers(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredCustomers = _allCustomers;
      } else {
        final lowerQuery = query.toLowerCase();
        _filteredCustomers = _allCustomers.where((c) {
          final name = (c['name'] ?? '').toString().toLowerCase();
          final code = (c['code'] ?? '').toString().toLowerCase();
          return name.contains(lowerQuery) || code.contains(lowerQuery);
        }).toList();
      }
    });
  }

  Future<void> _saveAssignments() async {
    if (_selectedSalesman == null) return;
    
    setState(() => _isSaving = true);
    try {
      final salesmanCode = _selectedSalesman!.salesmanCode;
      await ApiService.assignCustomersToSalesman(
        salesmanCode,
        _assignedCustomerCodes.toList(),
      );
      
      // Update local data so we don't have to refetch
      for (var i = 0; i < _allCustomers.length; i++) {
        final code = _allCustomers[i]['code'].toString();
        if (_assignedCustomerCodes.contains(code)) {
          _allCustomers[i]['assigned'] = salesmanCode;
        } else if (_allCustomers[i]['assigned'] == salesmanCode) {
          _allCustomers[i]['assigned'] = '';
        }
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Assignments saved successfully!'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save assignments: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Widget _buildSalesmanSelector() {
    return Expanded(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search Salesman by Name or Code',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onChanged: (val) => setState(() => _salesmanSearchQuery = val),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _filteredSalesmen.length,
              itemBuilder: (context, index) {
                final s = _filteredSalesmen[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFF2362EC).withOpacity(0.1),
                    child: const Icon(Icons.person, color: Color(0xFF2362EC)),
                  ),
                  title: Text(s.salesmanName ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('Code: ${s.salesmanCode}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _onSalesmanSelected(s),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomerAssignmentList() {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(16.0),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedSalesman!.salesmanName ?? 'Unknown',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Code: ${_selectedSalesman!.salesmanCode} • Customer Assignment',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.65),
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _onSalesmanSelected(null),
                    icon: const Icon(Icons.change_circle_rounded),
                    label: const Text('Change'),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search Customers',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onChanged: _filterCustomers,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            alignment: Alignment.centerLeft,
            child: Text(
              'Assigned: ${_assignedCustomerCodes.length} / ${_allCustomers.length}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              itemCount: _filteredCustomers.length,
              itemBuilder: (context, index) {
                final customer = _filteredCustomers[index];
                final code = customer['code'].toString();
                final isAssigned = _assignedCustomerCodes.contains(code);
                final name = customer['name']?.toString() ?? 'Unknown';
                final assignedToOther = customer['assigned'] != null && 
                                        customer['assigned'].toString().isNotEmpty && 
                                        customer['assigned'] != _selectedSalesman!.salesmanCode;

                return Card(
                  margin: const EdgeInsets.only(bottom: 8.0),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: isAssigned ? const Color(0xFF2362EC).withOpacity(0.5) : Colors.grey.shade200,
                      width: isAssigned ? 2 : 1,
                    ),
                  ),
                  child: SwitchListTile(
                    activeColor: const Color(0xFF2362EC),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                    secondary: CircleAvatar(
                      backgroundColor: (isAssigned ? const Color(0xFF2362EC) : Colors.grey.shade400).withOpacity(0.1),
                      child: Icon(
                        Icons.store_rounded,
                        color: isAssigned ? const Color(0xFF2362EC) : Colors.grey.shade600,
                      ),
                    ),
                    title: Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '$code ${assignedToOther ? '(Assigned to: ${customer['assigned']})' : ''}',
                      style: TextStyle(color: assignedToOther ? Colors.orange.shade700 : Colors.grey.shade600),
                    ),
                    value: isAssigned,
                    onChanged: (bool checked) {
                      setState(() {
                        if (checked) {
                          _assignedCustomerCodes.add(code);
                        } else {
                          _assignedCustomerCodes.remove(code);
                        }
                      });
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        title: const Text('Assign Customers'),
        backgroundColor: const Color(0xFF2362EC),
        foregroundColor: Colors.white,
        actions: [
          if (_selectedSalesman != null)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: _isSaving 
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16.0),
                      child: SizedBox(
                        width: 20, height: 20, 
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                      )
                    )
                  )
                : IconButton(
                    icon: const Icon(Icons.save_rounded),
                    onPressed: _saveAssignments,
                    tooltip: 'Save Assignments',
                  ),
            )
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_selectedSalesman == null)
                  _buildSalesmanSelector()
                else
                  _buildCustomerAssignmentList(),
              ],
            ),
    );
  }
}
