import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/device_tracking_service.dart';

class AdminDeviceTrackingPage extends StatefulWidget {
  const AdminDeviceTrackingPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<AdminDeviceTrackingPage> createState() =>
      _AdminDeviceTrackingPageState();
}

class _AdminDeviceTrackingPageState extends State<AdminDeviceTrackingPage> {
  final _search = TextEditingController();
  bool _isLoading = true;
  String? _error;
  String _typeFilter = 'All';
  int _maxAllowed = 5;
  int _allowedCount = 0;
  int _pendingCount = 0;
  List<Map<String, dynamic>> _devices = [];

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final summary = await DeviceTrackingService.getAllDevices();
      if (!mounted) return;
      setState(() {
        _devices = summary.devices;
        _maxAllowed = summary.maxAllowed;
        _allowedCount = summary.allowedCount;
        _pendingCount = summary.pendingCount;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredDevices {
    final query = _search.text.trim().toLowerCase();
    return _devices.where((device) {
      final userType = device['userType']?.toString() ?? '';

      if (_typeFilter == 'Not Allowed' && deviceIsAllowed(device)) {
        return false;
      }
      if (_typeFilter == 'Allowed' && !deviceIsAllowed(device)) {
        return false;
      }
      if (_typeFilter != 'All' &&
          _typeFilter != 'Not Allowed' &&
          _typeFilter != 'Allowed' &&
          userType != _typeFilter) {
        return false;
      }

      if (query.isEmpty) return true;

      final haystack = [
        device['userCode'],
        device['userName'],
        device['deviceName'],
        device['deviceModel'],
        device['platform'],
        device['isAllowed']?.toString(),
      ].map((value) => value?.toString().toLowerCase() ?? '').join(' ');

      return haystack.contains(query);
    }).toList();
  }

  String _formatDate(dynamic value) {
    if (value == null) return '-';
    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) return value.toString();
    return DateFormat('yyyy-MM-dd HH:mm').format(parsed.toLocal());
  }

  Color _statusColor(String status, bool isAllowed) {
    if (!isAllowed) return Colors.orange;
    return status == 'Active' ? Colors.green : Colors.grey;
  }

  Color _typeColor(String userType) {
    switch (userType) {
      case 'Admin':
        return Colors.orange;
      default:
        return const Color(0xFF598DC9);
    }
  }

  IconData _platformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return Icons.android_rounded;
      case 'ios':
        return Icons.phone_iphone_rounded;
      default:
        return Icons.devices_other_rounded;
    }
  }

  List<Map<String, dynamic>> get _allowedDevices =>
      _devices.where(deviceIsAllowed).toList();

  Future<void> _approveDevice(Map<String, dynamic> device) async {
    final auth = context.read<AuthProvider>();
    final deviceId = device['deviceId']?.toString() ?? '';
    if (deviceId.isEmpty) return;

    String? replaceDeviceId;
    if (_allowedCount >= _maxAllowed) {
      replaceDeviceId = await _pickReplacementDevice(
        excludeDeviceId: deviceId,
      );
      if (replaceDeviceId == null) return;
    }

    try {
      await DeviceTrackingService.approveDevice(
        deviceId: deviceId,
        approvedBy: auth.salesmanName,
        replaceDeviceId: replaceDeviceId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Device approved for ${device['userName']}')),
      );
      await _loadDevices();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<String?> _pickReplacementDevice({required String excludeDeviceId}) {
    final options = _allowedDevices
        .where((d) => d['deviceId']?.toString() != excludeDeviceId)
        .toList();

    if (options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No approved device available to replace.'),
        ),
      );
      return Future.value(null);
    }

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace Device'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Maximum $_maxAllowed devices are already approved. '
                'Select one device to revoke and allow this new device.',
              ),
              const SizedBox(height: 12),
              ...options.map((device) {
                final label =
                    '${device['userName']} • ${device['deviceModel'] ?? device['deviceName']}';
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(label),
                  subtitle: Text(device['userCode']?.toString() ?? ''),
                  onTap: () =>
                      Navigator.pop(context, device['deviceId']?.toString()),
                );
              }),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _revokeDevice(Map<String, dynamic> device) async {
    final auth = context.read<AuthProvider>();
    final deviceId = device['deviceId']?.toString() ?? '';
    if (deviceId.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke Device'),
        content: Text(
          'Revoke access for ${device['userName']} on '
          '${device['deviceModel'] ?? device['deviceName']}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await DeviceTrackingService.revokeDevice(
        deviceId: deviceId,
        revokedBy: auth.salesmanName,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device access revoked')),
      );
      await _loadDevices();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filteredDevices;

    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        automaticallyImplyLeading: widget.appBarLeading == null,
        title: const Text('Device Tracking'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _isLoading ? null : _loadDevices,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Installed Devices',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Only $_maxAllowed devices can be approved. '
                  'Extra devices wait for super admin approval.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.black54,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _SummaryChip(
                      label: 'Allowed',
                      value: '$_allowedCount/$_maxAllowed',
                      color: _allowedCount >= _maxAllowed
                          ? Colors.red
                          : Colors.green,
                    ),
                    _SummaryChip(
                      label: 'Not Allowed',
                      value: '$_pendingCount',
                      color: Colors.orange,
                    ),
                    _SummaryChip(
                      label: 'Total',
                      value: '${_devices.length}',
                      color: const Color(0xFF598DC9),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search user, device, platform...',
                    prefixIcon: const Icon(Icons.search_rounded),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    'All',
                    'Allowed',
                    'Not Allowed',
                    'Admin',
                    'Salesman',
                  ].map((type) {
                    final selected = _typeFilter == type;
                    return FilterChip(
                      label: Text(type),
                      selected: selected,
                      onSelected: (_) => setState(() => _typeFilter = type),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Failed to load devices',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.red,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _loadDevices,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : filtered.isEmpty
                ? Center(
                    child: Text(
                      _devices.isEmpty
                          ? 'No devices registered yet.\nDevices appear after users log in.'
                          : 'No devices match your search.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: Colors.black54,
                      ),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadDevices,
                    child: ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final device = filtered[index];
                        final userType =
                            device['userType']?.toString() ?? 'Salesman';
                        final status =
                            device['status']?.toString() ?? 'Inactive';
                        final isAllowed = deviceIsAllowed(device);
                        final platform =
                            device['platform']?.toString() ?? 'unknown';

                        return Card(
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                              color: !isAllowed
                                  ? Colors.orange.withValues(alpha: 0.5)
                                  : Colors.black12,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor: _typeColor(userType)
                                          .withValues(alpha: 0.12),
                                      child: Icon(
                                        _platformIcon(platform),
                                        color: _typeColor(userType),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            device['userName']?.toString() ??
                                                '-',
                                            style: theme.textTheme.titleMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                          Text(
                                            '${device['userCode']?.toString() ?? '-'} • $userType',
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: Colors.black54,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _statusColor(
                                          status,
                                          isAllowed,
                                        ).withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        isAllowed ? status : 'Not Allowed',
                                        style: TextStyle(
                                          color: _statusColor(
                                            status,
                                            isAllowed,
                                          ),
                                          fontWeight: FontWeight.w600,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                _InfoRow(
                                  label: 'Device',
                                  value:
                                      device['deviceModel']
                                              ?.toString()
                                              .trim()
                                              .isNotEmpty ==
                                          true
                                      ? device['deviceModel'].toString()
                                      : device['deviceName']?.toString() ??
                                            '-',
                                ),
                                _InfoRow(
                                  label: 'Platform',
                                  value:
                                      '${platform.toUpperCase()} • ${device['osVersion'] ?? '-'}',
                                ),
                                _InfoRow(
                                  label: 'App Version',
                                  value: device['appVersion']?.toString() ?? '-',
                                ),
                                _InfoRow(
                                  label: 'isAllowed',
                                  value: isAllowed ? '1' : '0',
                                ),
                                _InfoRow(
                                  label: 'Approved By',
                                  value: device['approvedBy']?.toString() ?? '-',
                                ),
                                _InfoRow(
                                  label: 'Last Seen',
                                  value: _formatDate(device['lastSeenAt']),
                                ),
                                if (!isAllowed) ...[
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      onPressed: () => _approveDevice(device),
                                      icon: const Icon(Icons.check_circle),
                                      label: const Text('Allow Device'),
                                    ),
                                  ),
                                ],
                                if (isAllowed) ...[
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: () => _revokeDevice(device),
                                      icon: const Icon(Icons.block),
                                      label: const Text('Revoke Device'),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _SummaryChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.black54,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
