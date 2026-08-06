import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';

/// Feature keys match `gen_salesmanUseRights` columns / API payload.
class _UseRightFeature {
  const _UseRightFeature({
    required this.key,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  final String key;
  final String label;
  final String subtitle;
  final IconData icon;
  final Color color;
}

const List<_UseRightFeature> _salesmanFeatures = [
  _UseRightFeature(
    key: 'CanSalesOrder',
    label: 'Sales Order',
    subtitle: 'Create and post sales orders',
    icon: Icons.shopping_cart_rounded,
    color: Color(0xFF598DC9),
  ),
  _UseRightFeature(
    key: 'CanInvoice',
    label: 'Invoice',
    subtitle: 'Create and post invoices',
    icon: Icons.request_quote_rounded,
    color: Color(0xFF10B981),
  ),
  _UseRightFeature(
    key: 'CanQuotation',
    label: 'Quotation',
    subtitle: 'Create and post quotations',
    icon: Icons.description_rounded,
    color: Color(0xFF22C55E),
  ),
  _UseRightFeature(
    key: 'CanCRN',
    label: 'CRN',
    subtitle: 'Customer returns / credit notes',
    icon: Icons.assignment_return_rounded,
    color: Color(0xFFEF4444),
  ),
  _UseRightFeature(
    key: 'CanMySalesHistory',
    label: 'My Sales & History',
    subtitle: 'View own sales and document history',
    icon: Icons.payments_rounded,
    color: Color(0xFF598DC9),
  ),
  _UseRightFeature(
    key: 'CanCustomerCreate',
    label: 'Customer Registration',
    subtitle: 'Register new customers',
    icon: Icons.person_add_alt_1_rounded,
    color: Color(0xFFF59E0B),
  ),
  _UseRightFeature(
    key: 'CanCustomerLocations',
    label: 'Customer Locations',
    subtitle: 'View and update customer locations',
    icon: Icons.map_rounded,
    color: Color(0xFF0EA5E9),
  ),
  _UseRightFeature(
    key: 'CanLeaderboard',
    label: 'LeaderBoard',
    subtitle: 'View salesman leaderboard',
    icon: Icons.leaderboard_rounded,
    color: Color(0xFFF59E0B),
  ),
  _UseRightFeature(
    key: 'CanStockReports',
    label: 'Stock Reports',
    subtitle: 'View stock reports',
    icon: Icons.bar_chart_rounded,
    color: Color(0xFF0EA5E9),
  ),
  _UseRightFeature(
    key: 'CanReceipts',
    label: 'Receipts',
    subtitle: 'Create and manage receipts',
    icon: Icons.receipt_long_rounded,
    color: Color(0xFF598DC9),
  ),
];

const List<_UseRightFeature> _adminFeatures = [
  _UseRightFeature(
    key: 'CanAdminSalesmanLocationHistory',
    label: 'Salesmans Location History',
    subtitle: 'View salesman location history',
    icon: Icons.route_rounded,
    color: Color(0xFF7C3AED),
  ),
  _UseRightFeature(
    key: 'CanAdminUserCreation',
    label: 'User Creation',
    subtitle: 'Create and manage salesman accounts',
    icon: Icons.person_add_alt_1_rounded,
    color: Color(0xFF8B5CF6),
  ),
  _UseRightFeature(
    key: 'CanAdminSalesAndHistory',
    label: 'Sales & History',
    subtitle: 'Admin sales and history reports',
    icon: Icons.history_rounded,
    color: Color(0xFF0D9488),
  ),
  _UseRightFeature(
    key: 'CanInvoice',
    label: 'Invoice',
    subtitle: 'Create and post invoices for customers',
    icon: Icons.request_quote_rounded,
    color: Color(0xFF10B981),
  ),
  _UseRightFeature(
    key: 'CanCRN',
    label: 'CRN',
    subtitle: 'Create and post customer returns',
    icon: Icons.assignment_return_rounded,
    color: Color(0xFFEF4444),
  ),
  _UseRightFeature(
    key: 'CanLeaderboard',
    label: 'LeaderBoard',
    subtitle: 'View leaderboard',
    icon: Icons.leaderboard_rounded,
    color: Color(0xFFF59E0B),
  ),
  _UseRightFeature(
    key: 'CanAdminLocationTracking',
    label: 'Location Tracking',
    subtitle: 'Live salesman location tracking',
    icon: Icons.location_on_rounded,
    color: Color(0xFF10B981),
  ),
  _UseRightFeature(
    key: 'CanAdminCurrentSale',
    label: 'Current Sale',
    subtitle: 'View current sales activity',
    icon: Icons.point_of_sale_rounded,
    color: Color(0xFF598DC9),
  ),
];

List<_UseRightFeature> get _allFeatures {
  final seen = <String>{};
  final all = <_UseRightFeature>[];
  for (final f in [..._salesmanFeatures, ..._adminFeatures]) {
    if (seen.add(f.key)) all.add(f);
  }
  return all;
}

Map<String, bool> _defaultRights() => {
      for (final f in _allFeatures)
        f.key: f.key != 'CanStockReports' && f.key != 'CanReceipts',
    };

class SuperAdminUseRightsPage extends StatefulWidget {
  const SuperAdminUseRightsPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<SuperAdminUseRightsPage> createState() =>
      _SuperAdminUseRightsPageState();
}

class _SuperAdminUseRightsPageState extends State<SuperAdminUseRightsPage> {
  final _search = TextEditingController();
  Timer? _searchDebounce;

  bool _isSearching = false;
  bool _hasSearched = false;
  bool _isLoadingRights = false;
  bool _isSaving = false;
  List<Map<String, dynamic>> _searchResults = [];

  String? _selectedCode;
  String? _selectedName;
  bool _selectedIsAdmin = false;
  Map<String, bool> _rights = _defaultRights();

  List<_UseRightFeature> get _visibleFeatures =>
      _selectedIsAdmin ? _adminFeatures : _salesmanFeatures;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _hasSearched = false;
      });
      return;
    }
    setState(() => _hasSearched = false);
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      _searchSalesmen(showEmptyMessage: false);
    });
  }

  Future<void> _searchSalesmen({bool showEmptyMessage = true}) async {
    final query = _search.text.trim();
    if (query.isEmpty) {
      if (showEmptyMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter salesman code or name to search'),
          ),
        );
      }
      setState(() {
        _searchResults = [];
        _hasSearched = false;
      });
      return;
    }

    setState(() => _isSearching = true);
    try {
      final results = await ApiService.searchSalesmen(query);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _hasSearched = true;
      });
      if (results.isEmpty && showEmptyMessage) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No salesmen found')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Search failed: $e')));
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<void> _selectSalesman(Map<String, dynamic> salesman) async {
    final code =
        (salesman['SalesmanCode'] ?? salesman['salesmanCode'] ?? '')
            .toString()
            .trim();
    final name =
        (salesman['SalesmanName'] ?? salesman['salesmanName'] ?? code)
            .toString()
            .trim();
    if (code.isEmpty) return;

    final isAdmin =
        salesman['isAdmin'] == true ||
        salesman['isAdmin'] == 1 ||
        (salesman['SalesmanType']?.toString().toLowerCase() == 'admin');

    setState(() {
      _selectedCode = code;
      _selectedName = name;
      _selectedIsAdmin = isAdmin;
      _isLoadingRights = true;
      _searchResults = [];
      _search.text = '$code — $name';
    });

    try {
      final rights = await ApiService.getSalesmanUseRights(code);
      if (!mounted) return;
      setState(() {
        _rights = {
          for (final f in _allFeatures)
            f.key: rights[f.key] == true || rights[f.key] == 1,
        };
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _rights = _defaultRights());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load rights: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoadingRights = false);
    }
  }

  Future<void> _saveRights() async {
    final code = _selectedCode;
    if (code == null || code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a salesman first')),
      );
      return;
    }

    final auth = context.read<AuthProvider>();
    setState(() => _isSaving = true);
    try {
      await ApiService.updateSalesmanUseRights(
        salesmanCode: code,
        rights: _rights,
        editedUser: auth.salesmanName,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('User rights saved for $code'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Save failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _setAll(bool enabled) {
    setState(() {
      for (final f in _visibleFeatures) {
        _rights[f.key] = enabled;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();
    final hasAccess = auth.isSuper || auth.isAdmin;

    if (!hasAccess) {
      return Scaffold(
        appBar: AppBar(
          leading: widget.appBarLeading,
          title: const Text('User Rights'),
        ),
        body: const Center(child: Text('Super admin access required.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        automaticallyImplyLeading: widget.appBarLeading == null,
        title: const Text('User Rights'),
        backgroundColor: const Color(0xFF7C3AED).withValues(alpha: 0.1),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF7C3AED).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFF7C3AED).withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              auth.isSuper ? 'SUPER ADMIN' : 'ADMIN',
              style: theme.textTheme.labelSmall?.copyWith(
                color: const Color(0xFF7C3AED),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Enable or disable app sections for each salesman or admin.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Find salesman',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _search,
                            decoration: InputDecoration(
                              hintText: 'Search by code or name',
                              prefixIcon: const Icon(Icons.search_rounded),
                              suffixIcon: _isSearching
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : IconButton(
                                      tooltip: 'Search',
                                      onPressed: () => _searchSalesmen(),
                                      icon: const Icon(Icons.search_rounded),
                                    ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onChanged: _onSearchChanged,
                            onSubmitted: (_) => _searchSalesmen(),
                          ),
                          if (_hasSearched && _searchResults.isNotEmpty) ...[
                            const SizedBox(height: 12),
                              ..._searchResults.map((s) {
                              final code =
                                  (s['SalesmanCode'] ?? '').toString();
                              final name =
                                  (s['SalesmanName'] ?? '').toString();
                              final isAdmin =
                                  s['isAdmin'] == true ||
                                  s['isAdmin'] == 1 ||
                                  (s['SalesmanType']?.toString()
                                          .toLowerCase() ==
                                      'admin');
                              final selected = code == _selectedCode;
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: const Color(
                                    0xFF7C3AED,
                                  ).withValues(alpha: 0.12),
                                  child: const Icon(
                                    Icons.person_rounded,
                                    color: Color(0xFF7C3AED),
                                  ),
                                ),
                                title: Text(name),
                                subtitle: Text(
                                  '$code • ${isAdmin ? 'Admin' : 'Salesman'}',
                                ),
                                selected: selected,
                                trailing: selected
                                    ? const Icon(
                                        Icons.check_circle,
                                        color: Color(0xFF7C3AED),
                                      )
                                    : null,
                                onTap: () => _selectSalesman(s),
                              );
                            }),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (_selectedCode != null) ...[
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _selectedName ?? '',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      Text(
                                        'Code: $_selectedCode • ${_selectedIsAdmin ? 'Admin portal sections' : 'Salesman app sections'}',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                          color: theme.colorScheme.onSurface
                                              .withValues(alpha: 0.65),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton(
                                  onPressed: _isLoadingRights || _isSaving
                                      ? null
                                      : () => _setAll(true),
                                  child: const Text('Enable all'),
                                ),
                                TextButton(
                                  onPressed: _isLoadingRights || _isSaving
                                      ? null
                                      : () => _setAll(false),
                                  child: const Text('Disable all'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (_isLoadingRights)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 32),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else
                              ..._visibleFeatures.map((feature) {
                                final enabled = _rights[feature.key] ?? false;
                                return SwitchListTile(
                                  value: enabled,
                                  onChanged: _isSaving
                                      ? null
                                      : (value) {
                                          setState(() {
                                            _rights[feature.key] = value;
                                          });
                                        },
                                  secondary: CircleAvatar(
                                    backgroundColor:
                                        feature.color.withValues(alpha: 0.14),
                                    child: Icon(
                                      feature.icon,
                                      color: feature.color,
                                      size: 20,
                                    ),
                                  ),
                                  title: Text(
                                    feature.label,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(feature.subtitle),
                                  activeThumbColor: feature.color,
                                );
                              }),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _isLoadingRights || _isSaving
                                  ? null
                                  : _saveRights,
                              icon: _isSaving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.save_rounded),
                              label: Text(
                                _isSaving ? 'Saving…' : 'Save user rights',
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF7C3AED),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
