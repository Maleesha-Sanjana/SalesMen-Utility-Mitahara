import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';

class AdminUserManagementPage extends StatefulWidget {
  const AdminUserManagementPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<AdminUserManagementPage> createState() =>
      _AdminUserManagementPageState();
}

class _AdminUserManagementPageState extends State<AdminUserManagementPage> {
  final _formKey = GlobalKey<FormState>();
  final _search = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _mobile = TextEditingController();

  bool _isSaving = false;
  bool _isSearching = false;
  bool _obscurePassword = true;
  bool _isRecalledSalesman = false;
  bool _hasSearched = false;
  String _accessLevel = 'sales';
  List<Map<String, dynamic>> _searchResults = [];
  Timer? _searchDebounce;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    _code.dispose();
    _name.dispose();
    _password.dispose();
    _mobile.dispose();
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
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _saveSalesman() async {
    if (!_formKey.currentState!.validate()) return;

    final auth = context.read<AuthProvider>();
    setState(() => _isSaving = true);

    try {
      if (_isRecalledSalesman) {
        await ApiService.updateSalesmanAccessLevel(
          salesmanCode: _code.text.trim(),
          accessLevel: _accessLevel,
          editedUser: auth.salesmanName,
        );

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Salesman ${_code.text.trim()} access level updated successfully',
            ),
          ),
        );
      } else {
        final response = await ApiService.createSalesman(
          salesmanName: _name.text.trim(),
          password: _password.text.trim(),
          mobile: _mobile.text.trim(),
          salesmanType: _accessLevel,
          createdUser: auth.salesmanName,
          isAdmin: _accessLevel == 'admin',
        );

        final salesman = response['salesman'] as Map<String, dynamic>? ?? {};
        _code.text = salesman['SalesmanCode']?.toString() ?? '';

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Salesman ${_code.text.isEmpty ? '' : '${_code.text} '}saved successfully',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _fillSalesman(Map<String, dynamic> salesman) {
    final isAdmin = salesman['isAdmin'] == true || salesman['isAdmin'] == 1;

    setState(() {
      _code.text = salesman['SalesmanCode']?.toString() ?? '';
      _name.text = salesman['SalesmanName']?.toString() ?? '';
      _password.text = salesman['password']?.toString() ?? '';
      _mobile.text = salesman['Mobile']?.toString() ?? '';
      _accessLevel = isAdmin ? 'admin' : 'sales';
      _isRecalledSalesman = true;
      _searchResults = [];
      _hasSearched = false;
    });
  }

  void _clearForm() {
    _formKey.currentState?.reset();
    setState(() {
      _search.clear();
      _code.clear();
      _name.clear();
      _password.clear();
      _mobile.clear();
      _searchResults = [];
      _hasSearched = false;
      _accessLevel = 'sales';
      _obscurePassword = true;
      _isRecalledSalesman = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();
    final hasAccess = auth.isAdmin || auth.isSuper;

    if (!hasAccess) {
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
        title: const Text('Salesman Creation'),
        backgroundColor: Colors.red.withValues(alpha: 0.1),
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
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: Colors.red.withValues(alpha: 0.1),
                            child: const Icon(
                              Icons.person_add_alt_1,
                              color: Colors.red,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _isRecalledSalesman
                                      ? 'Recall Salesman'
                                      : 'Create Salesman User',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  _isRecalledSalesman
                                      ? 'Only access level can be changed for recalled salesmen.'
                                      : 'Records are saved directly to gen_salesman.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.7),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
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
                            'Recall Existing Salesman',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _search,
                                  textInputAction: TextInputAction.search,
                                  decoration: const InputDecoration(
                                    labelText: 'Type salesman code or name',
                                    prefixIcon: Icon(Icons.search),
                                  ),
                                  onChanged: _onSearchChanged,
                                  onSubmitted: (_) => _searchSalesmen(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filled(
                                tooltip: 'Search',
                                onPressed: _isSearching
                                    ? null
                                    : _searchSalesmen,
                                icon: _isSearching
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.search),
                              ),
                            ],
                          ),
                          if (_searchResults.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            ..._searchResults.map(
                              (salesman) => Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  leading: const Icon(Icons.person_outline),
                                  title: Text(
                                    salesman['SalesmanName']?.toString() ?? '',
                                  ),
                                  subtitle: Text(
                                    '${salesman['SalesmanCode'] ?? ''} • ${salesman['isAdmin'] == true || salesman['isAdmin'] == 1 ? 'Admin' : 'Salesman'}',
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => _fillSalesman(salesman),
                                ),
                              ),
                            ),
                          ] else if (_search.text.trim().isNotEmpty &&
                              _hasSearched &&
                              !_isSearching) ...[
                            const SizedBox(height: 12),
                            Text(
                              'No matching salesmen',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextFormField(
                              controller: _code,
                              readOnly: true,
                              decoration: const InputDecoration(
                                labelText: 'Salesman Code',
                                hintText: 'Automatically generated after save',
                                prefixIcon: Icon(Icons.badge_outlined),
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _name,
                              readOnly: _isRecalledSalesman,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: 'Salesman Name *',
                                prefixIcon: Icon(Icons.person_outline),
                              ),
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) {
                                  return 'Salesman name is required';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _password,
                              readOnly: _isRecalledSalesman,
                              obscureText:
                                  _obscurePassword && !_isRecalledSalesman,
                              decoration: InputDecoration(
                                labelText: 'Password *',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: _isRecalledSalesman
                                    ? null
                                    : IconButton(
                                        icon: Icon(
                                          _obscurePassword
                                              ? Icons.visibility_outlined
                                              : Icons.visibility_off_outlined,
                                        ),
                                        onPressed: () {
                                          setState(
                                            () => _obscurePassword =
                                                !_obscurePassword,
                                          );
                                        },
                                      ),
                              ),
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) {
                                  return 'Password is required';
                                }
                                if (value.trim().length > 50) {
                                  return 'Password must be 50 characters or less';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _mobile,
                              readOnly: _isRecalledSalesman,
                              keyboardType: TextInputType.phone,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: 'Mobile',
                                prefixIcon: Icon(Icons.phone_outlined),
                              ),
                            ),
                            const SizedBox(height: 14),
                            DropdownButtonFormField<String>(
                              value: _accessLevel,
                              decoration: const InputDecoration(
                                labelText: 'Access Level',
                                prefixIcon: Icon(Icons.security_outlined),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'sales',
                                  child: Text('Salesman'),
                                ),
                                DropdownMenuItem(
                                  value: 'admin',
                                  child: Text('Admin'),
                                ),
                              ],
                              onChanged: (value) {
                                if (value == null) return;
                                setState(() => _accessLevel = value);
                              },
                            ),
                            const SizedBox(height: 20),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _isSaving ? null : _clearForm,
                                    icon: const Icon(Icons.clear),
                                    label: const Text('Clear'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: _isSaving ? null : _saveSalesman,
                                    icon: _isSaving
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.save_outlined),
                                    label: Text(
                                      _isSaving
                                          ? 'Saving...'
                                          : _isRecalledSalesman
                                          ? 'Update Access'
                                          : 'Save Salesman',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
