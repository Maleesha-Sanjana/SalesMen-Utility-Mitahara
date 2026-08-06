import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import '../providers/auth_provider.dart';
import '../services/location_service.dart';
import '../services/location_realtime_service.dart';
import 'dart:async';

class AdminLocationTrackingPage extends StatefulWidget {
  const AdminLocationTrackingPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<AdminLocationTrackingPage> createState() =>
      _AdminLocationTrackingPageState();
}

class _AdminLocationTrackingPageState extends State<AdminLocationTrackingPage> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final LocationRealtimeService _realtimeService = LocationRealtimeService();
  Timer? _refreshTimer;
  List<Map<String, dynamic>> userLocations = [];
  List<Map<String, dynamic>> customerLocations = [];
  bool _isLoading = true;
  String _searchQuery = '';

  // Default map center (Colombo, Sri Lanka)
  static const LatLng _initialCenter = LatLng(6.9271, 79.8612);
  static const double _initialZoom = 8.0;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadUserLocations();
    _connectRealtimeUpdates();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _loadUserLocations();
    });
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.trim().toLowerCase();
    });
  }

  Map<String, String> get _salesmanNameByCode {
    final map = <String, String>{};
    for (final user in userLocations) {
      final code = user['userCode']?.toString().trim().toUpperCase() ?? '';
      if (code.isEmpty) continue;
      map[code] = (user['userName'] ?? user['name'] ?? '').toString();
    }
    return map;
  }

  bool _matchesUserSearch(Map<String, dynamic> user, String query) {
    if (query.isEmpty) return true;
    final name =
        (user['userName'] ?? user['name'] ?? '').toString().toLowerCase();
    final code = user['userCode']?.toString().toLowerCase() ?? '';
    return name.contains(query) || code.contains(query);
  }

  bool _matchesCustomerSearch(Map<String, dynamic> customer, String query) {
    if (query.isEmpty) return true;
    final name = customer['customerName']?.toString().toLowerCase() ?? '';
    final code = customer['customerCode']?.toString().toLowerCase() ?? '';
    final repCode =
        customer['salesRepCode']?.toString().trim().toUpperCase() ?? '';
    final repName = _salesmanNameByCode[repCode]?.toLowerCase() ?? '';
    return name.contains(query) ||
        code.contains(query) ||
        repName.contains(query) ||
        repCode.toLowerCase().contains(query);
  }

  List<Map<String, dynamic>> get _filteredUserLocations => userLocations
      .where((user) => _matchesUserSearch(user, _searchQuery))
      .toList();

  List<Map<String, dynamic>> get _filteredCustomerLocations => customerLocations
      .where((customer) => _matchesCustomerSearch(customer, _searchQuery))
      .toList();

  Future<void> _connectRealtimeUpdates() async {
    try {
      await _realtimeService.connect(
        onUpdate: (_) {
          if (mounted) {
            _loadUserLocations(silent: true);
          }
        },
      );
    } catch (e) {
      print('⚠️ Realtime location updates unavailable: $e');
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _refreshTimer?.cancel();
    _realtimeService.disconnect();
    super.dispose();
  }

  /// Load user locations from server
  Future<void> _loadUserLocations({bool silent = false}) async {
    try {
      final auth = context.read<AuthProvider>();

      // Super Admin gets all user types, regular Admin gets only salesmen
      final locations = auth.isSuper
          ? await LocationService.getAllUserLocationsWithTypes()
          : await LocationService.getAllUserLocations();
      final customers = await LocationService.getCustomerLocations();

      if (mounted) {
        setState(() {
          userLocations = locations;
          customerLocations = customers;
          if (!silent) {
            _isLoading = false;
          }
        });
        print(
          '📍 Loaded ${locations.length} user locations and ${customers.length} customer locations',
        );
        _fitMapToMarkers();
      }
    } catch (e) {
      print('❌ Error loading user locations: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          // Fallback to sample data if server fails
          userLocations = _getSampleData();
          customerLocations = [];
        });
      }
    }
  }

  /// Fallback sample data
  List<Map<String, dynamic>> _getSampleData() {
    return [
      {
        'userCode': 'U001',
        'userName': 'John Doe',
        'latitude': 6.9271,
        'longitude': 79.8612,
        'address': 'Colombo, Sri Lanka',
        'timestamp': DateTime.now()
            .subtract(const Duration(minutes: 2))
            .toIso8601String(),
        'accuracy': 5.0,
        'speed': 0.0,
        'status': 'Active',
      },
      {
        'userCode': 'U002',
        'userName': 'Jane Smith',
        'latitude': 6.0535,
        'longitude': 80.2210,
        'address': 'Galle, Sri Lanka',
        'timestamp': DateTime.now()
            .subtract(const Duration(minutes: 5))
            .toIso8601String(),
        'accuracy': 8.0,
        'speed': 2.5,
        'status': 'Active',
      },
      {
        'userCode': 'U003',
        'userName': 'Mike Johnson',
        'latitude': 7.2906,
        'longitude': 80.6337,
        'address': 'Kandy, Sri Lanka',
        'timestamp': DateTime.now()
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
        'accuracy': 12.0,
        'speed': 0.0,
        'status': 'Inactive',
      },
    ];
  }

  List<Marker> _createMarkers() {
    final auth = context.read<AuthProvider>();

    final userMarkers = _filteredUserLocations.where(_hasValidCoordinates).map((user) {
      final isActive = _isUserActive(user);
      final userName = user['userName'] ?? user['name'] ?? 'Unknown';
      final userType = user['userType'] ?? 'Salesman';

      // Different colors based on user type (only for Super Admin)
      Color markerColor;
      IconData markerIcon;

      if (auth.isSuper) {
        // Super Admin sees different colors for different user types
        switch (userType) {
          case 'Super Admin':
            markerColor = isActive
                ? Colors.purple
                : Colors.purple.withValues(alpha: 0.6);
            markerIcon = Icons.admin_panel_settings;
            break;
          case 'Admin':
            markerColor = isActive
                ? Colors.red
                : Colors.red.withValues(alpha: 0.6);
            markerIcon = Icons.admin_panel_settings;
            break;
          default: // Salesman
            markerColor = isActive ? Colors.green : Colors.orange;
            markerIcon = Icons.person_pin_circle;
        }
      } else {
        // Regular Admin sees only salesmen with standard colors
        markerColor = isActive ? Colors.green : Colors.orange;
        markerIcon = Icons.person_pin_circle;
      }

      return Marker(
        point: LatLng(
          _toDouble(user['latitude']),
          _toDouble(user['longitude']),
        ),
        width: 90,
        height: 90,
        child: GestureDetector(
          onTap: () => _showUserDetails(context, user),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: markerColor,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isActive) ...[
                      Icon(Icons.access_time, color: Colors.white, size: 12),
                      const SizedBox(width: 2),
                    ],
                    if (auth.isSuper && userType != 'Salesman') ...[
                      Icon(
                        Icons.admin_panel_settings,
                        color: Colors.white,
                        size: 12,
                      ),
                      const SizedBox(width: 2),
                    ],
                    Flexible(
                      child: Text(
                        userName.split(' ')[0],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(markerIcon, color: markerColor, size: 30),
            ],
          ),
        ),
      );
    }).toList();

    final customerMarkers = _filteredCustomerLocations.where(_hasValidCoordinates).map((customer) {
      final customerName =
          customer['customerName']?.toString().trim().isNotEmpty == true
          ? customer['customerName'].toString()
          : 'Customer';

      return Marker(
        point: LatLng(
          _toDouble(customer['latitude']),
          _toDouble(customer['longitude']),
        ),
        width: 130,
        height: 96,
        child: GestureDetector(
          onTap: () => _showCustomerDetails(context, customer),
          child: Column(
            children: [
              Container(
                constraints: const BoxConstraints(maxWidth: 126),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.storefront, color: Colors.white, size: 12),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        customerName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.location_on, color: Colors.blue, size: 32),
            ],
          ),
        ),
      );
    }).toList();

    return [...userMarkers, ...customerMarkers];
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  bool _hasValidCoordinates(Map<String, dynamic> item) {
    final latitude = _toDouble(item['latitude']);
    final longitude = _toDouble(item['longitude']);
    return latitude != 0.0 && longitude != 0.0;
  }

  void _fitMapToMarkers() {
    if (_allMapLocations.isEmpty || !mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _allMapLocations.isEmpty) return;
      final bounds = _calculateBounds();
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(50),
        ),
      );
    });
  }

  DateTime? _parseLocationTime(Map<String, dynamic> user) {
    for (final key in ['timestamp', 'updated_at', 'lastUpdate', 'checkedInAt']) {
      final raw = user[key];
      if (raw == null || raw.toString().trim().isEmpty) continue;
      try {
        if (raw is DateTime) return raw.toLocal();
        final parsed = DateTime.parse(raw.toString());
        return parsed.isUtc ? parsed.toLocal() : parsed;
      } catch (_) {}
    }
    return null;
  }

  bool _isUserActive(Map<String, dynamic> user) {
    final timestamp = _parseLocationTime(user);
    
    // If we have a location timestamp, use it to determine if they are currently online/tracking
    if (timestamp != null) {
      // 15 minutes is a good threshold since foreground pushes every 30s and background pushes on movement
      return DateTime.now().difference(timestamp).inMinutes <= 15;
    }

    // Fallback to database status if no location time is available
    final status = user['status']?.toString();
    return status == 'Active';
  }

  String _getLastUpdateText(Map<String, dynamic> user) {
    final timestamp = _parseLocationTime(user);
    if (timestamp == null) {
      return user['lastUpdate']?.toString() ?? 'Unknown';
    }

    final exactTime = DateFormat('dd MMM yyyy, hh:mm a').format(timestamp);
    final difference = DateTime.now().difference(timestamp);

    if (difference.inMinutes < 1) {
      return '$exactTime (just now)';
    }
    if (difference.inMinutes < 60) {
      return '$exactTime (${difference.inMinutes} min ago)';
    }
    if (difference.inHours < 24) {
      return '$exactTime (${difference.inHours} hr ago)';
    }
    return '$exactTime (${difference.inDays} days ago)';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();

    // Check if user is admin or super admin
    if (!auth.isAdmin && !auth.isSuper) {
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
        title: Text(
          auth.isSuper
              ? 'All User Locations (Admins + Salesmen)'
              : 'Salesman Location Tracking',
        ),
        backgroundColor: Colors.green.withValues(alpha: 0.1),
        actions: [
          // Refresh button
          IconButton(
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _loadUserLocations,
            tooltip: 'Refresh locations',
          ),
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
                  auth.isSuper ? 'SUPER ADMIN ONLY' : 'ADMIN ONLY',
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
      body: Column(
        children: [
          // OpenStreetMap
          Expanded(
            flex: 2,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.green.withValues(alpha: 0.2)),
              ),
              child: Stack(
                children: [
                  // Map
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _initialCenter,
                      initialZoom: _initialZoom,
                      minZoom: 5.0,
                      maxZoom: 18.0,
                    ),
                    children: [
                      // OpenStreetMap tile layer
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName:
                            'com.maleeshasanjana.salesmanutility',
                        maxNativeZoom: 19,
                      ),
                      // User markers
                      MarkerLayer(markers: _createMarkers()),
                    ],
                  ),

                  // Zoom controls
                  Positioned(
                    right: 16,
                    top: 16,
                    child: Column(
                      children: [
                        // Zoom In button
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                final currentZoom = _mapController.camera.zoom;
                                if (currentZoom < 18.0) {
                                  _mapController.move(
                                    _mapController.camera.center,
                                    currentZoom + 1,
                                  );
                                }
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                width: 40,
                                height: 40,
                                child: const Icon(
                                  Icons.add,
                                  color: Colors.black87,
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 2),

                        // Zoom Out button
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                final currentZoom = _mapController.camera.zoom;
                                if (currentZoom > 5.0) {
                                  _mapController.move(
                                    _mapController.camera.center,
                                    currentZoom - 1,
                                  );
                                }
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                width: 40,
                                height: 40,
                                child: const Icon(
                                  Icons.remove,
                                  color: Colors.black87,
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Loading indicator
                  if (_isLoading)
                    Container(
                      color: Colors.black.withValues(alpha: 0.3),
                      child: const Center(
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // User list
          Expanded(
            flex: 1,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.05),
                border: Border(
                  top: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search salesman or customer name',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _searchQuery.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear_rounded),
                                onPressed: () => _searchController.clear(),
                                tooltip: 'Clear search',
                              ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        isDense: true,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            auth.isSuper
                                ? 'Users (${_filteredUserLocations.length}/${userLocations.length}) + Customers (${_filteredCustomerLocations.length}/${customerLocations.length})'
                                : 'Salesmen (${_filteredUserLocations.length}/${userLocations.length}) + Customers (${_filteredCustomerLocations.length}/${customerLocations.length})',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (auth.isSuper && userLocations.isNotEmpty) ...[
                          // Legend for Super Admin
                          PopupMenuButton<String>(
                            icon: Icon(Icons.info_outline, color: Colors.blue),
                            tooltip: 'Legend',
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                enabled: false,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Marker Types:',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.admin_panel_settings,
                                          color: Colors.purple,
                                          size: 16,
                                        ),
                                        SizedBox(width: 8),
                                        Text('Super Admin'),
                                      ],
                                    ),
                                    SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.admin_panel_settings,
                                          color: Colors.red,
                                          size: 16,
                                        ),
                                        SizedBox(width: 8),
                                        Text('Admin'),
                                      ],
                                    ),
                                    SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.person_pin_circle,
                                          color: Colors.green,
                                          size: 16,
                                        ),
                                        SizedBox(width: 8),
                                        Text('Salesman'),
                                      ],
                                    ),
                                    SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.storefront,
                                          color: Colors.blue,
                                          size: 16,
                                        ),
                                        SizedBox(width: 8),
                                        Text('Customer'),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 8),
                        ],
                        ElevatedButton.icon(
                          onPressed: () {
                            // Fit all markers in view
                            if (_allMapLocations.isNotEmpty) {
                              final bounds = _calculateBounds();
                              _mapController.fitCamera(
                                CameraFit.bounds(
                                  bounds: bounds,
                                  padding: const EdgeInsets.all(50),
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.center_focus_strong, size: 16),
                          label: const Text('View All'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _filteredUserLocations.isEmpty &&
                            _filteredCustomerLocations.isEmpty
                        ? Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 8,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _searchQuery.isEmpty
                                        ? Icons.location_off
                                        : Icons.search_off_rounded,
                                    size: 48,
                                    color: Colors.grey,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    _searchQuery.isEmpty
                                        ? 'No locations found'
                                        : 'No matching locations',
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      color: Colors.grey,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _searchQuery.isEmpty
                                        ? (auth.isSuper
                                            ? 'Admins and salesmen appear after they log in on a phone with location permission enabled and a working server connection. Super admin accounts are not tracked. Customer shops appear after creating customers with "Get Current Location".'
                                            : 'Salesmen appear after they log in with location permission enabled. Customer shops appear after creating customers with GPS coordinates.')
                                        : 'Try a different salesman or customer name.',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.grey,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _filteredUserLocations.length +
                                _filteredCustomerLocations.length,
                            itemBuilder: (context, index) {
                              if (index >= _filteredUserLocations.length) {
                                final customer =
                                    _filteredCustomerLocations[index -
                                        _filteredUserLocations.length];
                                final customerName =
                                    customer['customerName']?.toString() ??
                                    'Customer';

                                return Card(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: Colors.blue.withValues(
                                        alpha: 0.1,
                                      ),
                                      child: const Icon(
                                        Icons.storefront,
                                        color: Colors.blue,
                                      ),
                                    ),
                                    title: Text(
                                      customerName,
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      'Customer ${customer['customerCode'] ?? ''}\n${customer['latitude']}, ${customer['longitude']}',
                                      style: theme.textTheme.bodySmall,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: IconButton(
                                      icon: const Icon(
                                        Icons.my_location,
                                        size: 20,
                                      ),
                                      onPressed: () =>
                                          _focusOnCustomer(customer),
                                      tooltip: 'Focus on map',
                                    ),
                                    onTap: () =>
                                        _showCustomerDetails(context, customer),
                                  ),
                                );
                              }

                              final user = _filteredUserLocations[index];
                              final isActive = _isUserActive(user);
                              final userName =
                                  user['userName'] ?? user['name'] ?? 'Unknown';
                              final userType = user['userType'] ?? 'Salesman';
                              final auth = context.read<AuthProvider>();

                              // Different colors based on user type (only for Super Admin)
                              Color avatarColor;
                              IconData avatarIcon;

                              if (auth.isSuper) {
                                switch (userType) {
                                  case 'Super Admin':
                                    avatarColor = isActive
                                        ? Colors.purple
                                        : Colors.purple.withValues(alpha: 0.6);
                                    avatarIcon = Icons.admin_panel_settings;
                                    break;
                                  case 'Admin':
                                    avatarColor = isActive
                                        ? Colors.red
                                        : Colors.red.withValues(alpha: 0.6);
                                    avatarIcon = Icons.admin_panel_settings;
                                    break;
                                  default: // Salesman
                                    avatarColor = isActive
                                        ? Colors.green
                                        : Colors.orange;
                                    avatarIcon = Icons.person_pin_circle;
                                }
                              } else {
                                avatarColor = isActive
                                    ? Colors.green
                                    : Colors.orange;
                                avatarIcon = Icons.person_pin_circle;
                              }

                              return Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: avatarColor.withValues(
                                      alpha: 0.1,
                                    ),
                                    child: Icon(avatarIcon, color: avatarColor),
                                  ),
                                  title: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          userName,
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (auth.isSuper &&
                                          userType != 'Salesman') ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: userType == 'Super Admin'
                                                ? Colors.purple.withValues(
                                                    alpha: 0.1,
                                                  )
                                                : Colors.red.withValues(
                                                    alpha: 0.1,
                                                  ),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Text(
                                            userType,
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color:
                                                      userType == 'Super Admin'
                                                      ? Colors.purple
                                                      : Colors.red,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 10,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        user['address'] ??
                                            '${user['latitude']}, ${user['longitude']}',
                                        style: theme.textTheme.bodySmall,
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                      Text(
                                        isActive
                                            ? 'Latest location: ${_getLastUpdateText(user)}'
                                            : 'Last known location: ${_getLastUpdateText(user)}',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme.colorScheme.onSurface
                                                  .withValues(alpha: 0.6),
                                            ),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ],
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: avatarColor.withValues(
                                            alpha: 0.1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Text(
                                          isActive ? 'Active' : 'Inactive',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                color: avatarColor,
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.my_location,
                                          size: 20,
                                        ),
                                        onPressed: () => _focusOnUser(user),
                                        tooltip: 'Focus on map',
                                      ),
                                    ],
                                  ),
                                  onTap: () => _showUserDetails(context, user),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  LatLngBounds _calculateBounds() {
    final locationsToFit = _filteredUserLocations.where(_hasValidCoordinates).toList();
    final targetLocations = locationsToFit.isNotEmpty ? locationsToFit : _allMapLocations.where(_hasValidCoordinates).toList();

    if (targetLocations.isEmpty) {
      return LatLngBounds(const LatLng(6.0, 79.0), const LatLng(8.0, 81.0));
    }

    double minLat = _toDouble(targetLocations.first['latitude']);
    double maxLat = _toDouble(targetLocations.first['latitude']);
    double minLng = _toDouble(targetLocations.first['longitude']);
    double maxLng = _toDouble(targetLocations.first['longitude']);

    for (var item in targetLocations) {
      final latitude = _toDouble(item['latitude']);
      final longitude = _toDouble(item['longitude']);
      minLat = minLat < latitude ? minLat : latitude;
      maxLat = maxLat > latitude ? maxLat : latitude;
      minLng = minLng < longitude ? minLng : longitude;
      maxLng = maxLng > longitude ? maxLng : longitude;
    }

    if (minLat == maxLat && minLng == maxLng) {
      minLat -= 0.005;
      maxLat += 0.005;
      minLng -= 0.005;
      maxLng += 0.005;
    }

    return LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
  }

  List<Map<String, dynamic>> get _allMapLocations => [
    ..._filteredUserLocations,
    ..._filteredCustomerLocations,
  ];

  void _focusOnUser(Map<String, dynamic> user) {
    _mapController.move(
      LatLng(_toDouble(user['latitude']), _toDouble(user['longitude'])),
      15.0,
    );
  }

  void _focusOnCustomer(Map<String, dynamic> customer) {
    _mapController.move(
      LatLng(_toDouble(customer['latitude']), _toDouble(customer['longitude'])),
      15.0,
    );
  }

  void _showUserDetails(BuildContext context, Map<String, dynamic> user) {
    final userName = user['userName'] ?? user['name'] ?? 'Unknown';
    final userType = user['userType'] ?? 'Salesman';
    final auth = context.read<AuthProvider>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              userType == 'Salesman'
                  ? Icons.person_pin_circle
                  : Icons.admin_panel_settings,
              color: userType == 'Super Admin'
                  ? Colors.purple
                  : userType == 'Admin'
                  ? Colors.red
                  : Colors.green,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(userName),
                  if (auth.isSuper && userType != 'Salesman')
                    Text(
                      userType,
                      style: TextStyle(
                        fontSize: 14,
                        color: userType == 'Super Admin'
                            ? Colors.purple
                            : Colors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow('User Code:', user['userCode'] ?? 'N/A'),
            if (auth.isSuper) _buildDetailRow('User Type:', userType),
            _buildDetailRow(
              'Coordinates:',
              '${user['latitude']}, ${user['longitude']}',
            ),
            _buildDetailRow('Latest Location Time:', _getLastUpdateText(user)),
            _buildDetailRow(
              'Accuracy:',
              '${user['accuracy']?.toStringAsFixed(1) ?? 'N/A'} meters',
            ),
            _buildDetailRow(
              'Speed:',
              '${user['speed']?.toStringAsFixed(1) ?? '0'} m/s',
            ),
            _buildDetailRow(
              'Status:',
              _isUserActive(user) ? 'Active (Online)' : 'Inactive (Offline)',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _focusOnUser(user);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Focused on $userName location'),
                  backgroundColor: Colors.green,
                ),
              );
            },
            child: const Text('Show on Map'),
          ),
        ],
      ),
    );
  }

  void _showCustomerDetails(
    BuildContext context,
    Map<String, dynamic> customer,
  ) {
    final customerName = customer['customerName']?.toString() ?? 'Customer';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.storefront, color: Colors.blue),
            const SizedBox(width: 8),
            Expanded(child: Text(customerName)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow(
              'Code:',
              customer['customerCode']?.toString() ?? 'N/A',
            ),
            _buildDetailRow(
              'Sales Rep:',
              customer['salesRepCode']?.toString() ?? 'N/A',
            ),
            _buildDetailRow(
              'Coordinates:',
              '${customer['latitude']}, ${customer['longitude']}',
            ),
            _buildDetailRow(
              'Created:',
              customer['createdDate']?.toString() ?? 'N/A',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _focusOnCustomer(customer);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Focused on $customerName customer location'),
                  backgroundColor: Colors.blue,
                ),
              );
            },
            child: const Text('Show on Map'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
