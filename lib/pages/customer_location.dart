import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/auth_provider.dart';
import '../services/location_service.dart';

class CustomerLocationPage extends StatefulWidget {
  const CustomerLocationPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<CustomerLocationPage> createState() => _CustomerLocationPageState();
}

class _CustomerLocationPageState extends State<CustomerLocationPage> {
  static const Color _accentColor = Color(0xFF598DC9);
  static const LatLng _initialCenter = LatLng(6.9271, 79.8612);
  static const double _initialZoom = 8.0;

  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _allCustomers = [];
  List<Map<String, dynamic>> _filteredCustomers = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadCustomerLocations();
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.trim().toLowerCase();
      _applyFilter();
    });
  }

  void _applyFilter() {
    if (_searchQuery.isEmpty) {
      _filteredCustomers = List<Map<String, dynamic>>.from(_allCustomers);
      return;
    }

    _filteredCustomers = _allCustomers.where((customer) {
      final name = customer['customerName']?.toString().toLowerCase() ?? '';
      final code = customer['customerCode']?.toString().toLowerCase() ?? '';
      final location = customer['location']?.toString().toLowerCase() ?? '';
      return name.contains(_searchQuery) ||
          code.contains(_searchQuery) ||
          location.contains(_searchQuery);
    }).toList();
  }

  Future<void> _loadCustomerLocations() async {
    setState(() => _isLoading = true);

    try {
      final auth = context.read<AuthProvider>();
      final salesmanCode = auth.salesmanCode.trim().toUpperCase();
      final locations = await LocationService.getCustomerLocations();

      final scoped = salesmanCode.isEmpty
          ? locations
          : locations.where((customer) {
              final rep =
                  customer['salesRepCode']?.toString().trim().toUpperCase() ??
                  '';
              return rep.isEmpty || rep == salesmanCode;
            }).toList();

      if (!mounted) return;
      setState(() {
        _allCustomers = scoped.where(_hasValidCoordinates).toList();
        _applyFilter();
        _isLoading = false;
      });
      _fitMapToMarkers();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _allCustomers = [];
        _filteredCustomers = [];
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to load customer locations: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  bool _hasValidCoordinates(Map<String, dynamic> customer) {
    final latitude = _toDouble(customer['latitude']);
    final longitude = _toDouble(customer['longitude']);
    return latitude != 0.0 && longitude != 0.0;
  }

  LatLng _customerPoint(Map<String, dynamic> customer) {
    return LatLng(
      _toDouble(customer['latitude']),
      _toDouble(customer['longitude']),
    );
  }

  String _customerName(Map<String, dynamic> customer) {
    final name = customer['customerName']?.toString().trim();
    if (name != null && name.isNotEmpty) return name;
    return 'Customer';
  }

  void _fitMapToMarkers() {
    if (_filteredCustomers.isEmpty || !mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _filteredCustomers.isEmpty) return;
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: _calculateBounds(_filteredCustomers),
          padding: const EdgeInsets.all(50),
        ),
      );
    });
  }

  LatLngBounds _calculateBounds(List<Map<String, dynamic>> customers) {
    if (customers.isEmpty) {
      return LatLngBounds(const LatLng(6.0, 79.0), const LatLng(8.0, 81.0));
    }

    var minLat = _toDouble(customers.first['latitude']);
    var maxLat = minLat;
    var minLng = _toDouble(customers.first['longitude']);
    var maxLng = minLng;

    for (final customer in customers) {
      final latitude = _toDouble(customer['latitude']);
      final longitude = _toDouble(customer['longitude']);
      minLat = latitude < minLat ? latitude : minLat;
      maxLat = latitude > maxLat ? latitude : maxLat;
      minLng = longitude < minLng ? longitude : minLng;
      maxLng = longitude > maxLng ? longitude : maxLng;
    }

    return LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
  }

  void _focusOnCustomer(Map<String, dynamic> customer) {
    _mapController.move(_customerPoint(customer), 15.0);
  }

  Future<void> _openGoogleMapsNavigation(
    Map<String, dynamic> customer,
  ) async {
    final latitude = _toDouble(customer['latitude']);
    final longitude = _toDouble(customer['longitude']);
    final label = Uri.encodeComponent(_customerName(customer));

    final urls = [
      Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=$latitude,$longitude&travelmode=driving',
      ),
      Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude',
      ),
      Uri.parse('geo:$latitude,$longitude?q=$latitude,$longitude($label)'),
    ];

    for (final uri in urls) {
      if (await canLaunchUrl(uri)) {
        final launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (launched) return;
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open Google Maps on this device'),
        backgroundColor: Colors.red,
      ),
    );
  }

  List<Marker> _createMarkers() {
    return _filteredCustomers.map((customer) {
      final name = _customerName(customer);

      return Marker(
        point: _customerPoint(customer),
        width: 130,
        height: 96,
        child: GestureDetector(
          onTap: () => _showCustomerDetails(customer),
          child: Column(
            children: [
              Container(
                constraints: const BoxConstraints(maxWidth: 126),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _accentColor,
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
                        name,
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
              const Icon(Icons.location_on, color: _accentColor, size: 32),
            ],
          ),
        ),
      );
    }).toList();
  }

  void _showCustomerDetails(Map<String, dynamic> customer) {
    final name = _customerName(customer);

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: _accentColor.withValues(alpha: 0.12),
                    child: const Icon(Icons.storefront, color: _accentColor),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          customer['customerCode']?.toString() ?? '',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _detailRow(
                'Location',
                customer['location']?.toString().isNotEmpty == true
                    ? customer['location'].toString()
                    : '${customer['latitude']}, ${customer['longitude']}',
              ),
              _detailRow(
                'Coordinates',
                '${customer['latitude']}, ${customer['longitude']}',
              ),
              if (customer['mobile']?.toString().isNotEmpty == true)
                _detailRow('Mobile', customer['mobile'].toString()),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _focusOnCustomer(customer);
                      },
                      icon: const Icon(Icons.map_rounded),
                      label: const Text('Show on Map'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _accentColor,
                        side: const BorderSide(color: _accentColor),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _openGoogleMapsNavigation(customer);
                      },
                      icon: const Icon(Icons.navigation_rounded),
                      label: const Text('Google Maps'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _accentColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        title: const Text('Customer Locations'),
        backgroundColor: _accentColor.withValues(alpha: 0.08),
        actions: [
          IconButton(
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            onPressed: _isLoading ? null : _loadCustomerLocations,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _buildMapContent(theme),
    );
  }

  Widget _buildMapContent(ThemeData theme) {
    return Column(
        children: [
          Expanded(
            flex: 3,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _initialCenter,
                    initialZoom: _initialZoom,
                    minZoom: 5,
                    maxZoom: 18,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName:
                          'com.maleeshasanjana.salesmanutility',
                      maxNativeZoom: 19,
                    ),
                    MarkerLayer(markers: _createMarkers()),
                  ],
                ),
                if (_isLoading)
                  Container(
                    color: Colors.black.withValues(alpha: 0.2),
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                Positioned(
                  right: 16,
                  top: 16,
                  child: Column(
                    children: [
                      _mapIconButton(
                        icon: Icons.add,
                        onTap: () {
                          final zoom = _mapController.camera.zoom;
                          if (zoom < 18) {
                            _mapController.move(
                              _mapController.camera.center,
                              zoom + 1,
                            );
                          }
                        },
                      ),
                      const SizedBox(height: 4),
                      _mapIconButton(
                        icon: Icons.remove,
                        onTap: () {
                          final zoom = _mapController.camera.zoom;
                          if (zoom > 5) {
                            _mapController.move(
                              _mapController.camera.center,
                              zoom - 1,
                            );
                          }
                        },
                      ),
                      const SizedBox(height: 4),
                      _mapIconButton(
                        icon: Icons.center_focus_strong_rounded,
                        onTap: _fitMapToMarkers,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(
                  top: BorderSide(
                    color: theme.colorScheme.outline.withValues(alpha: 0.2),
                  ),
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search customer by name or code',
                        prefixIcon: const Icon(Icons.search_rounded),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        isDense: true,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${_filteredCustomers.length} customer(s) with GPS location',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: _accentColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _filteredCustomers.isEmpty
                        ? Center(
                            child: Text(
                              _isLoading
                                  ? 'Loading customer locations...'
                                  : 'No customer locations found.\nRegister customers with GPS to see them here.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            itemCount: _filteredCustomers.length,
                            itemBuilder: (context, index) {
                              final customer = _filteredCustomers[index];
                              final name = _customerName(customer);

                              return Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: _accentColor.withValues(
                                      alpha: 0.12,
                                    ),
                                    child: const Icon(
                                      Icons.storefront_rounded,
                                      color: _accentColor,
                                    ),
                                  ),
                                  title: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '${customer['customerCode'] ?? ''}\n${customer['location']?.toString().isNotEmpty == true ? customer['location'] : '${customer['latitude']}, ${customer['longitude']}'}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  isThreeLine: true,
                                  onTap: () => _showCustomerDetails(customer),
                                  trailing: Wrap(
                                    spacing: 4,
                                    children: [
                                      IconButton(
                                        tooltip: 'Show on map',
                                        icon: const Icon(Icons.map_rounded),
                                        color: _accentColor,
                                        onPressed: () =>
                                            _focusOnCustomer(customer),
                                      ),
                                      IconButton(
                                        tooltip: 'Navigate with Google Maps',
                                        icon: const Icon(Icons.navigation_rounded),
                                        color: _accentColor,
                                        onPressed: () =>
                                            _openGoogleMapsNavigation(customer),
                                      ),
                                    ],
                                  ),
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
    );
  }

  Widget _mapIconButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, color: Colors.black87, size: 20),
        ),
      ),
    );
  }
}
