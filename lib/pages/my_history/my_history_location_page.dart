import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/history_date_filter.dart';

class MyHistoryLocationPage extends StatefulWidget {
  const MyHistoryLocationPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<MyHistoryLocationPage> createState() => _MyHistoryLocationPageState();
}

class _MyHistoryLocationPageState extends State<MyHistoryLocationPage> {
  static const Color _accentColor = Color(0xFF0D9488);
  static const LatLng _defaultCenter = LatLng(6.9271, 79.8612);

  final MapController _mapController = MapController();
  final _searchController = TextEditingController();
  final _dateFormat = DateFormat('dd MMM yyyy, hh:mm a');

  DateTime? _fromDate;
  DateTime? _toDate;
  bool _isLoading = true;
  String? _error;
  List<Map<String, dynamic>> _entries = [];

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadEntries() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final auth = context.read<AuthProvider>();
      if (auth.salesmanCode.isEmpty) {
        throw Exception('Salesman information not available');
      }

      final entries = await ApiService.getSalesmanPlaceCheckInHistory(
        salesmanCode: auth.salesmanCode,
        fromDate: HistoryDateFilter.toApiDate(_fromDate),
        toDate: HistoryDateFilter.toApiDate(_toDate),
      );

      if (!mounted) return;
      setState(() {
        _entries = entries;
        _isLoading = false;
      });
      _fitMapToEntries(_filteredEntries);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  DateTime? _parseCheckedInAt(Map<String, dynamic> entry) {
    final raw = entry['checkedInAt'];
    if (raw == null || raw.toString().isEmpty) return null;
    try {
      if (raw is DateTime) return raw.toLocal();
      return DateTime.parse(raw.toString()).toLocal();
    } catch (_) {
      return null;
    }
  }

  LatLng? _entryLatLng(Map<String, dynamic> entry) {
    final lat = entry['latitude'];
    final lng = entry['longitude'];
    final latitude = lat is num
        ? lat.toDouble()
        : double.tryParse('$lat');
    final longitude = lng is num
        ? lng.toDouble()
        : double.tryParse('$lng');
    if (latitude == null ||
        longitude == null ||
        latitude == 0 ||
        longitude == 0) {
      return null;
    }
    return LatLng(latitude, longitude);
  }

  List<Map<String, dynamic>> get _filteredEntries {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _entries;

    return _entries.where((entry) {
      final placeName = entry['placeName']?.toString().toLowerCase() ?? '';
      final latitude = entry['latitude']?.toString() ?? '';
      final longitude = entry['longitude']?.toString() ?? '';
      return placeName.contains(query) ||
          latitude.contains(query) ||
          longitude.contains(query);
    }).toList();
  }

  List<Map<String, dynamic>> get _chronologicalEntries {
    final items = List<Map<String, dynamic>>.from(_filteredEntries);
    items.sort((a, b) {
      final aTime = _parseCheckedInAt(a) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = _parseCheckedInAt(b) ?? DateTime.fromMillisecondsSinceEpoch(0);
      return aTime.compareTo(bTime);
    });
    return items;
  }

  Map<String, int> get _visitNumbers {
    final numbers = <String, int>{};
    var index = 1;
    for (final entry in _chronologicalEntries) {
      final key = entry['id']?.toString() ??
          '${entry['checkedInAt']}_${entry['latitude']}_${entry['longitude']}';
      numbers[key] = index;
      index++;
    }
    return numbers;
  }

  String _entryKey(Map<String, dynamic> entry) {
    return entry['id']?.toString() ??
        '${entry['checkedInAt']}_${entry['latitude']}_${entry['longitude']}';
  }

  void _fitMapToEntries(List<Map<String, dynamic>> entries) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final points = entries
          .map(_entryLatLng)
          .whereType<LatLng>()
          .toList();
      if (points.isEmpty) {
        _mapController.move(_defaultCenter, 8);
        return;
      }
      if (points.length == 1) {
        _mapController.move(points.first, 14);
        return;
      }

      final bounds = LatLngBounds.fromPoints(points);
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(48),
        ),
      );
    });
  }

  List<Marker> _buildMarkers() {
    return _filteredEntries
        .map((entry) {
          final point = _entryLatLng(entry);
          if (point == null) return null;

          final checkedInAt = _parseCheckedInAt(entry);
          final placeName =
              entry['placeName']?.toString() ??
              '${entry['latitude']}, ${entry['longitude']}';

          return Marker(
            point: point,
            width: 14,
            height: 14,
            child: Tooltip(
              message: checkedInAt != null
                  ? '$placeName\n${_dateFormat.format(checkedInAt)}'
                  : placeName,
              child: Container(
                decoration: BoxDecoration(
                  color: _accentColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          );
        })
        .whereType<Marker>()
        .toList();
  }

  void _focusOnEntry(Map<String, dynamic> entry) {
    final point = _entryLatLng(entry);
    if (point == null) return;
    _mapController.move(point, 15);
  }

  void _zoomIn() {
    final currentZoom = _mapController.camera.zoom;
    if (currentZoom < 18) {
      _mapController.move(_mapController.camera.center, currentZoom + 1);
    }
  }

  void _zoomOut() {
    final currentZoom = _mapController.camera.zoom;
    if (currentZoom > 5) {
      _mapController.move(_mapController.camera.center, currentZoom - 1);
    }
  }

  Widget _buildZoomButton({
    required IconData icon,
    required VoidCallback onTap,
    required BorderRadius borderRadius,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: borderRadius,
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
          onTap: onTap,
          borderRadius: borderRadius,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, color: Colors.black87, size: 20),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filteredEntries;
    final markers = _buildMarkers();

    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        automaticallyImplyLeading: widget.appBarLeading == null,
        title: const Text('Location history'),
        backgroundColor: _accentColor.withValues(alpha: 0.08),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _loadEntries,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              children: [
                HistoryDateFilter(
                  fromDate: _fromDate,
                  toDate: _toDate,
                  accentColor: _accentColor,
                  onFromDateChanged: (date) {
                    setState(() => _fromDate = date);
                    _loadEntries();
                  },
                  onToDateChanged: (date) {
                    setState(() => _toDate = date);
                    _loadEntries();
                  },
                  onClear: () {
                    setState(() {
                      _fromDate = null;
                      _toDate = null;
                    });
                    _loadEntries();
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    labelText: 'Search place or coordinates',
                    prefixIcon: Icon(
                      Icons.location_on_rounded,
                      color: _accentColor,
                    ),
                  ),
                  onChanged: (_) {
                    setState(() {});
                    _fitMapToEntries(_filteredEntries);
                  },
                ),
              ],
            ),
          ),
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: _defaultCenter,
                        initialZoom: 8,
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
                        MarkerLayer(markers: markers),
                      ],
                    ),
                    if (!_isLoading && markers.isEmpty)
                      Container(
                        color: Colors.white.withValues(alpha: 0.85),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(24),
                        child: const Text(
                          'No map points for this date range.\nUse the location button in the menu to save places.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    Positioned(
                      left: 12,
                      bottom: 12,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Text(
                            'Each dot is a saved check-in location',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 12,
                      top: 12,
                      child: Column(
                        children: [
                          _buildZoomButton(
                            icon: Icons.add,
                            onTap: _zoomIn,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(8),
                            ),
                          ),
                          const SizedBox(height: 2),
                          _buildZoomButton(
                            icon: Icons.remove,
                            onTap: _zoomOut,
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _loadEntries,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  : filtered.isEmpty
                  ? const Center(
                      child: Text(
                        'No location check-ins found for this filter.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadEntries,
                      child: ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final entry = filtered[index];
                          final checkedInAt = _parseCheckedInAt(entry);
                          final latitude = entry['latitude'];
                          final longitude = entry['longitude'];
                          final placeName =
                              entry['placeName']?.toString() ??
                              '$latitude, $longitude';
                          final visitNo =
                              _visitNumbers[_entryKey(entry)] ?? index + 1;

                          return ListTile(
                            tileColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: theme.colorScheme.outline.withValues(
                                  alpha: 0.15,
                                ),
                              ),
                            ),
                            leading: CircleAvatar(
                              backgroundColor: _accentColor.withValues(
                                alpha: 0.12,
                              ),
                              child: Text(
                                '$visitNo',
                                style: const TextStyle(
                                  color: _accentColor,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            title: Text(
                              placeName,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              checkedInAt != null
                                  ? _dateFormat.format(checkedInAt)
                                  : entry['checkedInAt']?.toString() ?? '-',
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.my_location),
                              tooltip: 'Show on map',
                              onPressed: () => _focusOnEntry(entry),
                            ),
                            onTap: () => _focusOnEntry(entry),
                          );
                        },
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
