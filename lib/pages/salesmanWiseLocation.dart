import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import '../widgets/history_date_filter.dart';

const _kAllSalesmenFilter = '__all__';

class _SalesmanFilterOption {
  const _SalesmanFilterOption({required this.code, required this.label});

  final String code;
  final String label;
}

/// Admin view: salesman-wise location check-in history on a dotted map.
class SalesmanWiseLocationPage extends StatefulWidget {
  const SalesmanWiseLocationPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<SalesmanWiseLocationPage> createState() =>
      _SalesmanWiseLocationPageState();
}

class _SalesmanWiseLocationPageState extends State<SalesmanWiseLocationPage> {
  static const Color _accentColor = Color(0xFF7C3AED);
  static const LatLng _defaultCenter = LatLng(6.9271, 79.8612);

  static const List<Color> _salesmanPalette = [
    Color(0xFF7C3AED),
    Color(0xFF2563EB),
    Color(0xFFDC2626),
    Color(0xFFEA580C),
    Color(0xFF0891B2),
    Color(0xFF059669),
    Color(0xFFDB2777),
    Color(0xFFCA8A04),
    Color(0xFF4F46E5),
    Color(0xFF16A34A),
  ];

  static const Color _timeStartColor = Color(0xFF6366F1);
  static const Color _timeEndColor = Color(0xFFF97316);

  final MapController _mapController = MapController();
  final _dateFormat = DateFormat('dd MMM yyyy, hh:mm a');

  bool _isLoading = true;
  bool _isLoadingSalesmen = false;
  String? _error;
  List<Map<String, dynamic>> _filterSalesmen = [];
  List<Map<String, dynamic>> _entries = [];
  String _selectedSalesmanFilter = _kAllSalesmenFilter;
  DateTime? _fromDate;
  DateTime? _toDate;
  String? _selectedEntryKey;

  @override
  void initState() {
    super.initState();
    _loadSalesmen();
    _loadEntries();
  }

  List<_SalesmanFilterOption> get _salesmanFilterOptions {
    const allOption = _SalesmanFilterOption(
      code: _kAllSalesmenFilter,
      label: 'All salesmen',
    );
    final seen = <String>{};
    final options = <_SalesmanFilterOption>[allOption];

    for (final salesman in _filterSalesmen) {
      final code = salesman['salesmanCode']?.toString().trim() ?? '';
      if (code.isEmpty) continue;
      final dedupeKey = code.toUpperCase();
      if (seen.contains(dedupeKey)) continue;
      seen.add(dedupeKey);

      final name = salesman['salesmanName']?.toString().trim();
      options.add(
        _SalesmanFilterOption(
          code: code,
          label: '${name?.isNotEmpty == true ? name : code} ($code)',
        ),
      );
    }
    return options;
  }

  String get _effectiveSalesmanFilter {
    final allowed =
        _salesmanFilterOptions.map((option) => option.code).toSet();
    final selected = _selectedSalesmanFilter.trim();
    if (allowed.contains(selected)) return selected;
    return _kAllSalesmenFilter;
  }

  String get _salesmanFilterLabel {
    for (final option in _salesmanFilterOptions) {
      if (option.code == _effectiveSalesmanFilter) return option.label;
    }
    return 'All salesmen';
  }

  bool get _showAllSalesmen => _effectiveSalesmanFilter == _kAllSalesmenFilter;

  String? get _apiSalesmanCode =>
      _showAllSalesmen ? null : _effectiveSalesmanFilter.trim();

  Future<void> _loadSalesmen() async {
    setState(() => _isLoadingSalesmen = true);
    try {
      final salesmen = await ApiService.getAdminHistorySalesmen();
      if (!mounted) return;
      setState(() {
        _filterSalesmen = salesmen;
        _isLoadingSalesmen = false;
        if (!_salesmanFilterOptions
            .map((o) => o.code)
            .contains(_selectedSalesmanFilter)) {
          _selectedSalesmanFilter = _kAllSalesmenFilter;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingSalesmen = false);
    }
  }

  Future<void> _loadEntries() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _selectedEntryKey = null;
    });

    try {
      final entries = await ApiService.getAdminLocationCheckInHistory(
        salesmanCode: _apiSalesmanCode,
        fromDate: HistoryDateFilter.toApiDate(_fromDate),
        toDate: HistoryDateFilter.toApiDate(_toDate),
      );

      if (!mounted) return;
      setState(() {
        _entries = entries;
        _isLoading = false;
      });
      _fitMapToEntries(_entries);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([_loadSalesmen(), _loadEntries()]);
  }

  Future<void> _pickSalesman() async {
    final options = _salesmanFilterOptions;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: options.length,
            itemBuilder: (context, index) {
              final option = options[index];
              final isSelected = option.code == _effectiveSalesmanFilter;
              return ListTile(
                leading: Icon(
                  isSelected
                      ? Icons.check_circle_rounded
                      : Icons.person_outline_rounded,
                  color: isSelected ? _accentColor : null,
                ),
                title: Text(option.label),
                onTap: () => Navigator.of(sheetContext).pop(option.code),
              );
            },
          ),
        );
      },
    );

    if (!mounted || selected == null || selected == _effectiveSalesmanFilter) {
      return;
    }
    setState(() => _selectedSalesmanFilter = selected);
    _loadEntries();
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
    final latitude =
        lat is num ? lat.toDouble() : double.tryParse('$lat');
    final longitude =
        lng is num ? lng.toDouble() : double.tryParse('$lng');
    if (latitude == null ||
        longitude == null ||
        latitude == 0 ||
        longitude == 0) {
      return null;
    }
    return LatLng(latitude, longitude);
  }

  String _entryKey(Map<String, dynamic> entry) {
    return entry['id']?.toString() ??
        '${entry['checkedInAt']}_${entry['latitude']}_${entry['longitude']}';
  }

  List<Map<String, dynamic>> get _chronologicalEntries {
    final items = List<Map<String, dynamic>>.from(_entries);
    items.sort((a, b) {
      final aTime =
          _parseCheckedInAt(a) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime =
          _parseCheckedInAt(b) ?? DateTime.fromMillisecondsSinceEpoch(0);
      return aTime.compareTo(bTime);
    });
    return items;
  }

  Map<String, int> get _visitNumbers {
    final numbers = <String, int>{};
    var index = 1;
    for (final entry in _chronologicalEntries) {
      numbers[_entryKey(entry)] = index;
      index++;
    }
    return numbers;
  }

  Color _salesmanColor(String code) {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) return _accentColor;
    var hash = 0;
    for (final unit in normalized.codeUnits) {
      hash = (hash + unit) % _salesmanPalette.length;
    }
    return _salesmanPalette[hash];
  }

  Color _timeGradientColor(int visitIndex, int total) {
    if (total <= 1) return _timeStartColor;
    final t = (visitIndex - 1) / (total - 1);
    return Color.lerp(_timeStartColor, _timeEndColor, t) ?? _timeStartColor;
  }

  Color _dotColor(Map<String, dynamic> entry) {
    if (_showAllSalesmen) {
      return _salesmanColor(entry['salesmanCode']?.toString() ?? '');
    }
    final visitNo = _visitNumbers[_entryKey(entry)] ?? 1;
    return _timeGradientColor(visitNo, _chronologicalEntries.length);
  }

  Map<String, Color> get _legendColors {
    final legend = <String, Color>{};
    for (final entry in _entries) {
      final code = entry['salesmanCode']?.toString().trim() ?? '';
      if (code.isEmpty) continue;
      legend.putIfAbsent(
        code,
        () => _salesmanColor(code),
      );
    }
    return legend;
  }

  void _fitMapToEntriesWithController(
    MapController controller,
    List<Map<String, dynamic>> entries, {
    EdgeInsets padding = const EdgeInsets.all(48),
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final points = entries.map(_entryLatLng).whereType<LatLng>().toList();
      if (points.isEmpty) {
        controller.move(_defaultCenter, 8);
        return;
      }
      if (points.length == 1) {
        controller.move(points.first, 14);
        return;
      }
      controller.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: padding,
        ),
      );
    });
  }

  void _fitMapToEntries(List<Map<String, dynamic>> entries) {
    _fitMapToEntriesWithController(_mapController, entries);
  }

  void _openFullscreenMap() {
    if (_entries.isEmpty && !_isLoading) return;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) => _FullscreenSalesmanLocationMap(
          entries: _entries,
          selectedEntryKey: _selectedEntryKey,
          dotColorFor: _dotColor,
          entryKey: _entryKey,
          entryLatLng: _entryLatLng,
          onEntryTap: _showEntryDetails,
          onSelectedKeyChanged: (key) {
            if (mounted) setState(() => _selectedEntryKey = key);
          },
          buildLegend: _buildLegend,
          fitMapToEntries: _fitMapToEntriesWithController,
          initialCenter: _mapController.camera.center,
          initialZoom: _mapController.camera.zoom,
        ),
      ),
    );
  }

  List<Marker> _buildMarkersFor({
    required String? selectedEntryKey,
    required void Function(Map<String, dynamic> entry) onEntryTap,
  }) {
    return _entries
        .map((entry) {
          final point = _entryLatLng(entry);
          if (point == null) return null;

          final key = _entryKey(entry);
          final isSelected = selectedEntryKey == key;
          final color = _dotColor(entry);
          final size = isSelected ? 18.0 : 14.0;

          return Marker(
            point: point,
            width: size + 8,
            height: size + 8,
            child: GestureDetector(
              onTap: () => onEntryTap(entry),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? Colors.yellow : Colors.white,
                    width: isSelected ? 2.5 : 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.5),
                      blurRadius: isSelected ? 6 : 3,
                      spreadRadius: isSelected ? 1 : 0,
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

  Widget _buildMapStack({
    required MapController controller,
    required List<Marker> markers,
    required bool isFullscreen,
    VoidCallback? onMapBackgroundTap,
  }) {
    return Stack(
      children: [
        FlutterMap(
          mapController: controller,
          options: MapOptions(
            initialCenter: _defaultCenter,
            initialZoom: 8,
            minZoom: 5,
            maxZoom: 18,
            onTap: onMapBackgroundTap == null
                ? null
                : (_, __) => onMapBackgroundTap(),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.maleeshasanjana.salesmanutility',
              maxNativeZoom: 19,
            ),
            MarkerLayer(markers: markers),
          ],
        ),
        if (_isLoading && !isFullscreen)
          Container(
            color: Colors.white.withValues(alpha: 0.7),
            child: const Center(child: CircularProgressIndicator()),
          ),
        if (!_isLoading && markers.isEmpty)
          Container(
            color: Colors.white.withValues(alpha: 0.85),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(24),
            child: Text(
              isFullscreen
                  ? 'No location points to display.'
                  : 'No location history for this filter.\nReps save places using the location button in the menu.',
              textAlign: TextAlign.center,
            ),
          ),
        Positioned(
          left: 12,
          bottom: 12,
          right: 12,
          child: _buildLegend(),
        ),
        if (!isFullscreen)
          Positioned(
            left: 12,
            top: 12,
            child: _buildZoomButton(
              icon: Icons.fullscreen_rounded,
              onTap: _openFullscreenMap,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        Positioned(
          right: 12,
          top: 12,
          child: Column(
            children: [
              _buildZoomButton(
                icon: Icons.add,
                onTap: () {
                  final z = controller.camera.zoom;
                  if (z < 18) {
                    controller.move(controller.camera.center, z + 1);
                  }
                },
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(8),
                ),
              ),
              const SizedBox(height: 2),
              _buildZoomButton(
                icon: Icons.remove,
                onTap: () {
                  final z = controller.camera.zoom;
                  if (z > 5) {
                    controller.move(controller.camera.center, z - 1);
                  }
                },
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(8),
                ),
              ),
            ],
          ),
        ),
        if (!isFullscreen && !_isLoading && markers.isNotEmpty)
          Positioned(
            left: 56,
            top: 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  'Tap map to enlarge',
                  style: TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _focusOnEntry(Map<String, dynamic> entry) {
    final point = _entryLatLng(entry);
    if (point == null) return;
    setState(() => _selectedEntryKey = _entryKey(entry));
    _mapController.move(point, 15);
  }

  void _showEntryDetails(Map<String, dynamic> entry) {
    setState(() => _selectedEntryKey = _entryKey(entry));

    final salesmanName = entry['salesmanName']?.toString() ?? '-';
    final salesmanCode = entry['salesmanCode']?.toString() ?? '-';
    final placeName =
        entry['placeName']?.toString().trim().isNotEmpty == true
        ? entry['placeName'].toString()
        : '${entry['latitude']}, ${entry['longitude']}';
    final checkedInAt = _parseCheckedInAt(entry);
    final visitNo = _visitNumbers[_entryKey(entry)] ?? '-';
    final dotColor = _dotColor(entry);

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(color: Colors.black26, blurRadius: 3),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Visit #$visitNo',
                        style: Theme.of(sheetContext).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _detailRow('Salesman', '$salesmanName ($salesmanCode)'),
                _detailRow('Place', placeName),
                _detailRow(
                  'Checked in',
                  checkedInAt != null
                      ? _dateFormat.format(checkedInAt)
                      : entry['checkedInAt']?.toString() ?? '-',
                ),
                _detailRow(
                  'Coordinates',
                  '${entry['latitude']}, ${entry['longitude']}',
                ),
                if (entry['accuracy'] != null)
                  _detailRow('Accuracy', '${entry['accuracy']} m'),
                if (entry['remarks']?.toString().trim().isNotEmpty == true)
                  _detailRow('Remarks', entry['remarks'].toString()),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    _focusOnEntry(entry);
                  },
                  icon: const Icon(Icons.map_rounded),
                  label: const Text('Show on map'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _accentColor,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
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

  List<Marker> _buildMarkers() {
    return _buildMarkersFor(
      selectedEntryKey: _selectedEntryKey,
      onEntryTap: _showEntryDetails,
    );
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

  Widget _buildLegend() {
    if (_entries.isEmpty) return const SizedBox.shrink();

    if (!_showAllSalesmen) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: _timeStartColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              const Text('Earlier', style: TextStyle(fontSize: 10)),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    gradient: const LinearGradient(
                      colors: [_timeStartColor, _timeEndColor],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: _timeEndColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              const Text('Latest', style: TextStyle(fontSize: 10)),
            ],
          ),
        ),
      );
    }

    final legend = _legendColors.entries.toList();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Wrap(
          spacing: 10,
          runSpacing: 6,
          children: legend.map((item) {
            final name = _entries
                    .firstWhere(
                      (e) =>
                          (e['salesmanCode']?.toString().trim() ?? '') ==
                          item.key,
                      orElse: () => {'salesmanName': item.key},
                    )['salesmanName']
                    ?.toString() ??
                item.key;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: item.value,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  name,
                  style: const TextStyle(fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final markers = _buildMarkers();
    final visitNumbers = _visitNumbers;

    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        automaticallyImplyLeading: widget.appBarLeading == null,
        title: const Text('Salesmans Location History'),
        backgroundColor: _accentColor.withValues(alpha: 0.08),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _refreshAll,
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
                InkWell(
                  onTap: (_isLoading || _isLoadingSalesmen)
                      ? null
                      : _pickSalesman,
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Salesman filter',
                      prefixIcon: const Icon(
                        Icons.person_search_rounded,
                        color: _accentColor,
                      ),
                      suffixIcon: _isLoadingSalesmen
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : const Icon(Icons.arrow_drop_down_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      isDense: true,
                    ),
                    child: Text(
                      _isLoadingSalesmen
                          ? 'Loading salesmen...'
                          : _salesmanFilterLabel,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
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
                child: _buildMapStack(
                  controller: _mapController,
                  markers: markers,
                  isFullscreen: false,
                  onMapBackgroundTap: _openFullscreenMap,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _error != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _refreshAll,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  : _entries.isEmpty && !_isLoading
                  ? const Center(
                      child: Text(
                        'No check-in locations found.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _refreshAll,
                      child: ListView.separated(
                        itemCount: _chronologicalEntries.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final entry = _chronologicalEntries[
                              _chronologicalEntries.length - 1 - index];
                          final key = _entryKey(entry);
                          final checkedInAt = _parseCheckedInAt(entry);
                          final placeName =
                              entry['placeName']?.toString().trim().isNotEmpty ==
                                  true
                              ? entry['placeName'].toString()
                              : '${entry['latitude']}, ${entry['longitude']}';
                          final visitNo = visitNumbers[key] ?? index + 1;
                          final dotColor = _dotColor(entry);
                          final isSelected = _selectedEntryKey == key;

                          return ListTile(
                            onTap: () => _showEntryDetails(entry),
                            tileColor: isSelected
                                ? _accentColor.withValues(alpha: 0.06)
                                : Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: isSelected
                                    ? _accentColor.withValues(alpha: 0.4)
                                    : theme.colorScheme.outline.withValues(
                                        alpha: 0.15,
                                      ),
                              ),
                            ),
                            leading: CircleAvatar(
                              backgroundColor: dotColor.withValues(alpha: 0.18),
                              child: Text(
                                '$visitNo',
                                style: TextStyle(
                                  color: dotColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
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
                              '${entry['salesmanName'] ?? entry['salesmanCode'] ?? ''}\n'
                              '${checkedInAt != null ? _dateFormat.format(checkedInAt) : '-'}',
                            ),
                            isThreeLine: true,
                            trailing: IconButton(
                              icon: const Icon(Icons.my_location),
                              tooltip: 'Show on map',
                              onPressed: () => _focusOnEntry(entry),
                            ),
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

class _FullscreenSalesmanLocationMap extends StatefulWidget {
  const _FullscreenSalesmanLocationMap({
    required this.entries,
    required this.selectedEntryKey,
    required this.dotColorFor,
    required this.entryKey,
    required this.entryLatLng,
    required this.onEntryTap,
    required this.onSelectedKeyChanged,
    required this.buildLegend,
    required this.fitMapToEntries,
    required this.initialCenter,
    required this.initialZoom,
  });

  final List<Map<String, dynamic>> entries;
  final String? selectedEntryKey;
  final Color Function(Map<String, dynamic> entry) dotColorFor;
  final String Function(Map<String, dynamic> entry) entryKey;
  final LatLng? Function(Map<String, dynamic> entry) entryLatLng;
  final void Function(Map<String, dynamic> entry) onEntryTap;
  final ValueChanged<String?> onSelectedKeyChanged;
  final Widget Function() buildLegend;
  final void Function(
    MapController controller,
    List<Map<String, dynamic>> entries, {
    EdgeInsets padding,
  }) fitMapToEntries;
  final LatLng initialCenter;
  final double initialZoom;

  @override
  State<_FullscreenSalesmanLocationMap> createState() =>
      _FullscreenSalesmanLocationMapState();
}

class _FullscreenSalesmanLocationMapState
    extends State<_FullscreenSalesmanLocationMap> {
  static const _defaultCenter = LatLng(7.8731, 80.7718);

  late final MapController _mapController;
  String? _selectedEntryKey;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _selectedEntryKey = widget.selectedEntryKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.move(widget.initialCenter, widget.initialZoom);
      widget.fitMapToEntries(
        _mapController,
        widget.entries,
        padding: const EdgeInsets.all(64),
      );
    });
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  List<Marker> _buildMarkers() {
    return widget.entries
        .map((entry) {
          final point = widget.entryLatLng(entry);
          if (point == null) return null;

          final key = widget.entryKey(entry);
          final isSelected = _selectedEntryKey == key;
          final color = widget.dotColorFor(entry);
          final size = isSelected ? 20.0 : 16.0;

          return Marker(
            point: point,
            width: size + 8,
            height: size + 8,
            child: GestureDetector(
              onTap: () {
                setState(() => _selectedEntryKey = key);
                widget.onSelectedKeyChanged(key);
                widget.onEntryTap(entry);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? Colors.yellow : Colors.white,
                    width: isSelected ? 2.5 : 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.5),
                      blurRadius: isSelected ? 6 : 3,
                      spreadRadius: isSelected ? 1 : 0,
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
            width: 44,
            height: 44,
            child: Icon(icon, color: Colors.black87, size: 22),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final markers = _buildMarkers();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Location map'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.fit_screen_rounded),
            tooltip: 'Fit all points',
            onPressed: () => widget.fitMapToEntries(
              _mapController,
              widget.entries,
              padding: const EdgeInsets.all(64),
            ),
          ),
        ],
      ),
      body: Stack(
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
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.maleeshasanjana.salesmanutility',
                maxNativeZoom: 19,
              ),
              MarkerLayer(markers: markers),
            ],
          ),
          if (markers.isEmpty)
            Container(
              color: Colors.white.withValues(alpha: 0.85),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(24),
              child: const Text(
                'No location points to display.',
                textAlign: TextAlign.center,
              ),
            ),
          Positioned(
            left: 16,
            bottom: 16,
            right: 16,
            child: widget.buildLegend(),
          ),
          Positioned(
            right: 16,
            top: 16,
            child: Column(
              children: [
                _buildZoomButton(
                  icon: Icons.add,
                  onTap: () {
                    final z = _mapController.camera.zoom;
                    if (z < 18) {
                      _mapController.move(_mapController.camera.center, z + 1);
                    }
                  },
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(8),
                  ),
                ),
                const SizedBox(height: 2),
                _buildZoomButton(
                  icon: Icons.remove,
                  onTap: () {
                    final z = _mapController.camera.zoom;
                    if (z > 5) {
                      _mapController.move(_mapController.camera.center, z - 1);
                    }
                  },
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
