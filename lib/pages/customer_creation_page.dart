import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';
import '../services/offline_sync_service.dart';

enum _SearchAutoSelectMode { none, exactCodeOnly, bestMatch }

class CustomerCreationPage extends StatefulWidget {
  const CustomerCreationPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<CustomerCreationPage> createState() => _CustomerCreationPageState();
}

class _CustomerCreationPageState extends State<CustomerCreationPage> {
  static const Map<String, String> _taxGroups = {
    '1': 'NBT 1 & VAT',
    '2': 'NBT 2 & VAT',
    '3': 'VAT',
    '4': 'NBT & VAT',
    '5': 'NBT 1 & VAT',
  };

  static const List<String> _customerTypes = ['Trade', 'Income'];

  final _formKey = GlobalKey<FormState>();
  final _search = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _mobile = TextEditingController();
  final _nic = TextEditingController();
  final _creditLimit = TextEditingController(text: '0');
  final _creditPeriod = TextEditingController(text: '0');
  String _customerType = 'Trade';
  String _taxGroupCode = '1';
  double? _latitude;
  double? _longitude;
  bool _isSaving = false;
  bool _isSearching = false;
  bool _isGettingLocation = false;
  bool _isSyncing = false;
  bool _hasSearched = false;
  int _pendingCustomerCount = 0;
  List<Map<String, dynamic>> _searchResults = [];
  Timer? _searchDebounce;
  Map<String, dynamic>? _loadedCustomerSnapshot;

  @override
  void initState() {
    super.initState();
    _loadPendingCustomerCount();
    for (final controller in [
      _search,
      _name,
      _address,
      _city,
      _mobile,
      _nic,
      _creditLimit,
      _creditPeriod,
    ]) {
      controller.addListener(_onFormFieldChanged);
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    for (final controller in [
      _search,
      _name,
      _address,
      _city,
      _mobile,
      _nic,
      _creditLimit,
      _creditPeriod,
    ]) {
      controller.removeListener(_onFormFieldChanged);
    }
    _search.dispose();
    _code.dispose();
    _name.dispose();
    _address.dispose();
    _city.dispose();
    _mobile.dispose();
    _nic.dispose();
    _creditLimit.dispose();
    _creditPeriod.dispose();
    super.dispose();
  }

  /// Optional credit fields — empty or invalid → 0 for DB.
  double _parseCreditValue(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return 0;
    return double.tryParse(text) ?? 0;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    if (_nic.text.trim().isEmpty && _mobile.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter NIC or mobile number before saving customer'),
        ),
      );
      return;
    }

    final auth = context.read<AuthProvider>();
    final customerCode = _code.text.trim();
    final isUpdatingCustomer = customerCode.isNotEmpty;
    final hasGps = _latitude != null && _longitude != null;
    final currentLocation = hasGps
        ? '${_latitude!.toStringAsFixed(8)},${_longitude!.toStringAsFixed(8)}'
        : '';
    final payload = {
      'customerName': _name.text.trim(),
      'location': currentLocation,
      'latitude': _latitude,
      'longitude': _longitude,
      'mobile': _mobile.text.trim(),
      'customerId': _nic.text.trim(),
      'address1': _address.text.trim(),
      'address3': _city.text.trim(),
      'customerType': _customerType,
      'taxGroupCode': _taxGroupCode,
      'creditLimit': _parseCreditValue(_creditLimit),
      'creditPeriod': _parseCreditValue(_creditPeriod),
      'salesRepCode': auth.salesmanCode,
      'createdSalesman': auth.salesmanCode,
      'createdUser': auth.salesmanName,
    };

    setState(() => _isSaving = true);

    try {
      final serverAvailable = await ApiService.checkHealth();

      if (isUpdatingCustomer && !serverAvailable) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Internet is required to update recalled customers'),
          ),
        );
        return;
      }

      if (isUpdatingCustomer) {
        final response = await ApiService.updateCustomer(
          customerCode: customerCode,
          customerName: payload['customerName'].toString(),
          location: payload['location'].toString(),
          latitude: payload['latitude'] as double?,
          longitude: payload['longitude'] as double?,
          mobile: payload['mobile'].toString(),
          customerId: payload['customerId'].toString(),
          address1: payload['address1'].toString(),
          address3: payload['address3'].toString(),
          customerType: payload['customerType'].toString(),
          taxGroupCode: payload['taxGroupCode'].toString(),
          creditLimit: (payload['creditLimit'] as num?)?.toDouble() ?? 0,
          creditPeriod: (payload['creditPeriod'] as num?)?.toDouble() ?? 0,
          salesRepCode: payload['salesRepCode'].toString(),
          createdSalesman: payload['createdSalesman'].toString(),
          editedUser: payload['createdUser'].toString(),
        );

        final customer = response['customer'] as Map<String, dynamic>? ?? {};
        _fillCustomer(customer);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Customer ${customer['code'] ?? customerCode} updated successfully',
            ),
          ),
        );
        return;
      }

      if (!serverAvailable) {
        final customer = await OfflineSyncService.queueCustomerCreate(
          payload: payload,
        );
        _fillCustomer(customer);
        await _loadPendingCustomerCount();

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Offline area. Customer ${customer['code']} saved locally and will sync later.',
            ),
          ),
        );
        return;
      }

      final response = await ApiService.createCustomer(
        customerName: payload['customerName'].toString(),
        location: payload['location'].toString(),
        latitude: payload['latitude'] as double?,
        longitude: payload['longitude'] as double?,
        mobile: payload['mobile'].toString(),
        customerId: payload['customerId'].toString(),
        address1: payload['address1'].toString(),
        address3: payload['address3'].toString(),
        customerType: payload['customerType'].toString(),
        taxGroupCode: payload['taxGroupCode'].toString(),
        creditLimit: (payload['creditLimit'] as num?)?.toDouble() ?? 0,
        creditPeriod: (payload['creditPeriod'] as num?)?.toDouble() ?? 0,
        salesRepCode: payload['salesRepCode'].toString(),
        createdSalesman: payload['createdSalesman'].toString(),
        createdUser: payload['createdUser'].toString(),
      );

      final customer = response['customer'] as Map<String, dynamic>? ?? {};
      _fillCustomer(customer);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Customer ${customer['code'] ?? ''} saved successfully',
          ),
        ),
      );
    } catch (e) {
      if (isUpdatingCustomer) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update customer: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        return;
      }

      final errorText = e.toString();
      if (errorText.contains('already registered') ||
          errorText.contains('NIC or mobile')) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorText.replaceFirst('Exception: ', '')),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        return;
      }

      final customer = await OfflineSyncService.queueCustomerCreate(
        payload: payload,
      );
      _fillCustomer(customer);
      await _loadPendingCustomerCount();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Network problem. Customer ${customer['code']} saved locally.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
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
      _searchCustomer(
        showEmptyMessage: false,
        autoSelectMode: _SearchAutoSelectMode.exactCodeOnly,
      );
    });
  }

  Map<String, dynamic>? _findExactCodeMatch(
    List<Map<String, dynamic>> results,
    String query,
  ) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return null;

    for (final customer in results) {
      final code = customer['code']?.toString().trim().toLowerCase() ?? '';
      if (code == normalizedQuery) {
        return customer;
      }
    }

    return null;
  }

  Map<String, dynamic>? _findBestSearchMatch(
    List<Map<String, dynamic>> results,
    String query,
  ) {
    final exactMatch = _findExactCodeMatch(results, query);
    if (exactMatch != null) return exactMatch;

    if (results.length == 1) {
      return results.first;
    }

    return null;
  }

  Future<void> _searchCustomer({
    bool showEmptyMessage = true,
    _SearchAutoSelectMode autoSelectMode = _SearchAutoSelectMode.bestMatch,
  }) async {
    final query = _search.text.trim();
    if (query.isEmpty) {
      if (showEmptyMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter customer name or code to search'),
          ),
        );
      }
      setState(() {
        _searchResults = [];
        _hasSearched = false;
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    try {
      final auth = context.read<AuthProvider>();
      final results = await ApiService.searchCustomers(
        query,
        salesRepCode: '',
      );
      if (!mounted) return;

      final matchedCustomer = switch (autoSelectMode) {
        _SearchAutoSelectMode.exactCodeOnly =>
          _findExactCodeMatch(results, query),
        _SearchAutoSelectMode.bestMatch => _findBestSearchMatch(results, query),
        _SearchAutoSelectMode.none => null,
      };
      if (matchedCustomer != null) {
        _fillCustomer(matchedCustomer);
        return;
      }

      setState(() {
        _searchResults = results;
        _hasSearched = true;
      });

      if (results.isEmpty && showEmptyMessage) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No customer found')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to search customer: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<void> _captureLocation() async {
    setState(() => _isGettingLocation = true);

    try {
      final result = await LocationService.captureCurrentLocation();
      if (!mounted) return;

      if (!result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.message ?? 'Unable to get current location',
            ),
            action: result.canOpenSettings || result.canOpenLocationSettings
                ? SnackBarAction(
                    label: 'Settings',
                    onPressed: () {
                      if (result.canOpenLocationSettings) {
                        Geolocator.openLocationSettings();
                      } else {
                        Geolocator.openAppSettings();
                      }
                    },
                  )
                : null,
          ),
        );
        return;
      }

      final position = result.position!;
      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Location captured: ${position.latitude.toStringAsFixed(6)}, '
            '${position.longitude.toStringAsFixed(6)}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to get location: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isGettingLocation = false);
    }
  }

  void _onFormFieldChanged() {
    if (_loadedCustomerSnapshot != null) {
      setState(() {});
    }
  }

  void _captureCustomerSnapshot() {
    _loadedCustomerSnapshot = {
      'name': _name.text.trim(),
      'address': _address.text.trim(),
      'city': _city.text.trim(),
      'mobile': _mobile.text.trim(),
      'nic': _nic.text.trim(),
      'customerType': _customerType,
      'taxGroupCode': _taxGroupCode,
      'creditLimit': _parseCreditValue(_creditLimit),
      'creditPeriod': _parseCreditValue(_creditPeriod),
      'latitude': _latitude,
      'longitude': _longitude,
    };
  }

  bool _coordinatesEqual(double? a, double? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return (a - b).abs() < 0.0000001;
  }

  bool get _hasCustomerChanges {
    final snapshot = _loadedCustomerSnapshot;
    if (snapshot == null) return true;

    return _name.text.trim() != snapshot['name'] ||
        _address.text.trim() != snapshot['address'] ||
        _city.text.trim() != snapshot['city'] ||
        _mobile.text.trim() != snapshot['mobile'] ||
        _nic.text.trim() != snapshot['nic'] ||
        _customerType != snapshot['customerType'] ||
        _taxGroupCode != snapshot['taxGroupCode'] ||
        _parseCreditValue(_creditLimit) !=
            (snapshot['creditLimit'] as num?)?.toDouble() ||
        _parseCreditValue(_creditPeriod) !=
            (snapshot['creditPeriod'] as num?)?.toDouble() ||
        !_coordinatesEqual(_latitude, snapshot['latitude'] as double?) ||
        !_coordinatesEqual(_longitude, snapshot['longitude'] as double?);
  }

  void _fillCustomer(Map<String, dynamic> customer) {
    final type = customer['customerType']?.toString().trim() ?? '';
    final taxCode = customer['taxGroupCode']?.toString().trim() ?? '1';
    final code = customer['code']?.toString() ?? '';
    final name = customer['name']?.toString() ?? '';
    final creditLimit = _parseDouble(customer['creditLimit']) ?? 0;
    final creditPeriod = _parseDouble(customer['creditPeriod']) ?? 0;
    setState(() {
      _code.text = code;
      _name.text = name;
      _search.text = name.isEmpty ? code : '$code - $name';
      _address.text =
          customer['address1']?.toString() ??
          customer['address']?.toString() ??
          '';
      _city.text = customer['address3']?.toString() ?? '';
      _mobile.text =
          customer['mobile']?.toString() ?? customer['phone']?.toString() ?? '';
      _nic.text = customer['customerId']?.toString() ?? '';
      _customerType = _customerTypes.contains(type) ? type : 'Trade';
      _taxGroupCode = _taxGroups.containsKey(taxCode) ? taxCode : '1';
      _creditLimit.text = creditLimit.toStringAsFixed(0);
      _creditPeriod.text = creditPeriod.toStringAsFixed(0);
      _latitude = _parseDouble(customer['latitude']);
      _longitude = _parseDouble(customer['longitude']);
      _searchResults = [];
      _hasSearched = false;
    });
    _captureCustomerSnapshot();
  }

  Future<void> _loadPendingCustomerCount() async {
    final count = await OfflineSyncService.getPendingCustomerCount();
    if (!mounted) return;
    setState(() => _pendingCustomerCount = count);
  }

  Future<void> _syncPendingCustomers() async {
    setState(() => _isSyncing = true);

    try {
      final result = await OfflineSyncService.syncPendingCustomers();
      await _loadPendingCustomerCount();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message ??
                'Synced ${result.synced}. Failed ${result.failed}. Pending ${result.remaining}.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  double? _parseDouble(dynamic value) {
    if (value == null) return null;
    return double.tryParse(value.toString());
  }

  void _clearForm() {
    setState(() {
      _search.clear();
      _code.clear();
      _name.clear();
      _address.clear();
      _city.clear();
      _mobile.clear();
      _nic.clear();
      _customerType = 'Trade';
      _taxGroupCode = '1';
      _creditLimit.text = '0';
      _creditPeriod.text = '0';
      _latitude = null;
      _longitude = null;
      _searchResults = [];
      _hasSearched = false;
      _loadedCustomerSnapshot = null;
    });
  }

  String _formatCoordinate(double? value) {
    if (value == null) return 'Not captured';
    return value.toStringAsFixed(8);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasLoadedCustomer = _code.text.trim().isNotEmpty;
    final hasCapturedLocation = _latitude != null && _longitude != null;
    final canSubmitUpdate = !hasLoadedCustomer || _hasCustomerChanges;
    final canSave = canSubmitUpdate && !_isSaving;

    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        title: const Text('Customer Creation'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                Text(
                  'Enter customer details to save. GPS location is optional.',
                  style: theme.textTheme.bodyMedium,
                ),
                if (_pendingCustomerCount > 0) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: theme.colorScheme.primaryContainer.withValues(
                      alpha: 0.35,
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.cloud_upload_rounded),
                      title: Text(
                        '$_pendingCustomerCount customer(s) waiting to sync',
                      ),
                      subtitle: const Text(
                        'Saved locally while offline. Sync when internet is available.',
                      ),
                      trailing: TextButton(
                        onPressed: _isSyncing ? null : _syncPendingCustomers,
                        child: _isSyncing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Sync Now'),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    labelText: 'Search by customer code or name',
                    hintText: 'Enter customer code or name',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _isSearching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                  textInputAction: TextInputAction.search,
                  onChanged: _onSearchChanged,
                  onSubmitted: (_) =>
                      _searchCustomer(showEmptyMessage: true),
                ),
                if (_searchResults.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Column(
                      children: _searchResults.map((customer) {
                        final code = customer['code']?.toString() ?? '';
                        final name = customer['name']?.toString() ?? '';
                        return ListTile(
                          leading: const Icon(Icons.person_search_rounded),
                          title: Text(name.isEmpty ? code : name),
                          subtitle: Text(code),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => _fillCustomer(customer),
                        );
                      }).toList(),
                    ),
                  ),
                ] else if (_search.text.trim().isNotEmpty &&
                    _hasSearched &&
                    !_isSearching) ...[
                  const SizedBox(height: 12),
                  Text(
                    'No matching customers',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Customer Name'),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _address,
                  decoration: const InputDecoration(
                    labelText: 'Address:',
                    prefixIcon: Icon(Icons.home_rounded),
                  ),
                  maxLines: 2,
                  maxLength: 70,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _city,
                  decoration: const InputDecoration(
                    labelText: 'City:',
                    prefixIcon: Icon(Icons.location_city_rounded),
                  ),
                  maxLength: 70,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _mobile,
                  decoration: const InputDecoration(
                    labelText: 'Mobile:',
                    hintText: 'Required if NIC is empty',
                    prefixIcon: Icon(Icons.phone_rounded),
                  ),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _nic,
                  decoration: const InputDecoration(
                    labelText: 'NIC:',
                    hintText: 'Required if mobile is empty',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  maxLength: 15,
                  textCapitalization: TextCapitalization.characters,
                ),
                const SizedBox(height: 16),
                Text(
                  'Customer Type',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: _customerTypes
                      .map(
                        (type) => ButtonSegment<String>(
                          value: type,
                          label: Text(type),
                        ),
                      )
                      .toList(),
                  selected: {_customerType},
                  onSelectionChanged: (selection) {
                    setState(() => _customerType = selection.first);
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _creditLimit,
                        decoration: const InputDecoration(
                          labelText: 'Credit Limit',
                          hintText: 'Optional — default 0',
                          prefixIcon: Icon(Icons.account_balance_wallet_outlined),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _creditPeriod,
                        decoration: const InputDecoration(
                          labelText: 'Credit Period',
                          hintText: 'Optional — default 0',
                          prefixIcon: Icon(Icons.calendar_month_outlined),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'GPS Location',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _InfoRow(
                          label: 'Latitude',
                          value: _formatCoordinate(_latitude),
                        ),
                        _InfoRow(
                          label: 'Longitude',
                          value: _formatCoordinate(_longitude),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _isGettingLocation
                              ? null
                              : _captureLocation,
                          icon: _isGettingLocation
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.my_location_rounded),
                          label: const Text('Get Current Location'),
                        ),
                        if (!hasCapturedLocation) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Optional — tap Get Current Location if you want to save GPS.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.65,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: canSave ? _save : null,
                        icon: _isSaving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save_rounded),
                        label: Text(
                          hasLoadedCustomer
                              ? 'Update Customer'
                              : 'Save Customer',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: _isSaving ? null : _clearForm,
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                if (hasLoadedCustomer && !canSubmitUpdate) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Change at least one detail before updating this customer.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (hasLoadedCustomer && canSubmitUpdate) ...[
                  const SizedBox(height: 8),
                  Text(
                    'This customer is recalled. You can update the details or capture a new GPS location, then tap Update Customer.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
