import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/api_service.dart';
import '../../services/rep_document_recall_service.dart';
import '../../widgets/history_date_filter.dart';

const _kAllSalesmenFilter = '__all__';

class _SalesmanFilterOption {
  const _SalesmanFilterOption({required this.code, required this.label});

  final String code;
  final String label;
}

class AdminDocumentHistoryPage extends StatefulWidget {
  const AdminDocumentHistoryPage({
    super.key,
    required this.title,
    required this.documentType,
    required this.icon,
    this.accentColor = const Color(0xFF598DC9),
    this.emptyMessage = 'No records found for the selected filters.',
    this.appBarLeading,
  });

  final String title;
  final String documentType;
  final IconData icon;
  final Color accentColor;
  final String emptyMessage;
  final Widget? appBarLeading;

  @override
  State<AdminDocumentHistoryPage> createState() =>
      _AdminDocumentHistoryPageState();
}

class _AdminDocumentHistoryPageState extends State<AdminDocumentHistoryPage> {
  final _searchController = TextEditingController();
  final _currency = NumberFormat('#,##0.00');
  Timer? _searchDebounce;

  bool _isLoading = true;
  bool _isLoadingSalesmen = false;
  String? _error;
  List<Map<String, dynamic>> _filterSalesmen = [];
  AdminDocumentHistorySummary _summary = const AdminDocumentHistorySummary(
    documentCount: 0,
    salesmanCount: 0,
    grandTotal: 0,
  );
  List<AdminDocumentHistoryGroup> _groups = [];
  List<Map<String, dynamic>> _entries = [];
  String _selectedSalesmanFilter = _kAllSalesmenFilter;
  DateTime? _fromDate;
  DateTime? _toDate;
  String? _busyDocumentNo;
  final Set<String> _expandedGroups = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadSalesmen();
    _loadEntries();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), _loadEntries);
  }

  List<_SalesmanFilterOption> get _salesmanFilterOptions {
    const allOption = _SalesmanFilterOption(
      code: _kAllSalesmenFilter,
      label: 'All salesmen (grouped report)',
    );
    final seen = <String>{};
    final options = <_SalesmanFilterOption>[allOption];

    for (final salesman in _filterSalesmen) {
      final code = salesman['salesmanCode']?.toString().trim() ?? '';
      if (code.isEmpty || code == _kAllSalesmenFilter) continue;

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
    final allowedCodes =
        _salesmanFilterOptions.map((option) => option.code).toSet();
    final selected = _selectedSalesmanFilter.trim();
    if (allowedCodes.contains(selected)) return selected;
    return _kAllSalesmenFilter;
  }

  String get _salesmanFilterLabel {
    for (final option in _salesmanFilterOptions) {
      if (option.code == _effectiveSalesmanFilter) return option.label;
    }
    return 'All salesmen (grouped report)';
  }

  String? get _apiSalesmanCode => _effectiveSalesmanFilter == _kAllSalesmenFilter
      ? null
      : _effectiveSalesmanFilter.trim();

  Future<void> _pickSalesman() async {
    final options = _salesmanFilterOptions;
    final searchController = TextEditingController();
    var filtered = List<_SalesmanFilterOption>.from(options);

    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void applySearch(String query) {
              final normalized = query.trim().toLowerCase();
              setSheetState(() {
                filtered = normalized.isEmpty
                    ? List<_SalesmanFilterOption>.from(options)
                    : options
                          .where(
                            (option) => option.label.toLowerCase().contains(
                              normalized,
                            ),
                          )
                          .toList();
              });
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: TextField(
                        controller: searchController,
                        decoration: InputDecoration(
                          hintText: 'Search salesman from database',
                          prefixIcon: const Icon(Icons.search_rounded),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          isDense: true,
                        ),
                        onChanged: applySearch,
                      ),
                    ),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final option = filtered[index];
                          final isSelected =
                              option.code == _effectiveSalesmanFilter;

                          return ListTile(
                            leading: Icon(
                              isSelected
                                  ? Icons.check_circle_rounded
                                  : Icons.person_outline_rounded,
                              color: isSelected ? widget.accentColor : null,
                            ),
                            title: Text(option.label),
                            selected: isSelected,
                            onTap: () =>
                                Navigator.of(sheetContext).pop(option.code),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    searchController.dispose();

    if (!mounted || selected == null) return;
    if (selected == _effectiveSalesmanFilter) return;

    setState(() => _selectedSalesmanFilter = selected);
    _loadEntries();
  }

  Future<void> _loadSalesmen() async {
    setState(() => _isLoadingSalesmen = true);

    try {
      final salesmen = await ApiService.getAdminHistorySalesmen();
      if (!mounted) return;

      setState(() {
        _filterSalesmen = salesmen;
        _isLoadingSalesmen = false;

        final allowedCodes =
            _salesmanFilterOptions.map((option) => option.code).toSet();
        if (!allowedCodes.contains(_selectedSalesmanFilter.trim())) {
          _selectedSalesmanFilter = _kAllSalesmenFilter;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingSalesmen = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to load salesmen: ${e.toString().replaceFirst('Exception: ', '')}',
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _loadEntries() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await ApiService.getAdminDocumentHistory(
        documentType: widget.documentType,
        salesmanCode: _apiSalesmanCode,
        fromDate: HistoryDateFilter.toApiDate(_fromDate),
        toDate: HistoryDateFilter.toApiDate(_toDate),
        search: _searchController.text.trim(),
      );

      if (!mounted) return;
      setState(() {
        _summary = result.summary;
        _groups = result.groups;
        _entries = result.entries;
        _isLoading = false;
      });
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

  String _formatAmount(dynamic value) {
    final amount =
        value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
    return _currency.format(amount);
  }

  Future<void> _previewPdf(Map<String, dynamic> entry) async {
    final documentNo = entry['documentNo']?.toString() ?? '';
    if (documentNo.isEmpty) return;

    setState(() => _busyDocumentNo = documentNo);
    try {
      await RepDocumentRecallService.previewPdfFromHistoryEntry(
        context: context,
        documentType: widget.documentType,
        entry: entry,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _busyDocumentNo = null);
    }
  }

  void _showDocumentActions(Map<String, dynamic> entry) {
    final documentNo = entry['documentNo']?.toString() ?? '-';
    final customerName =
        entry['customerName']?.toString() ??
        entry['customerCode']?.toString() ??
        'Customer';
    final documentDate = entry['documentDate']?.toString() ?? '-';
    final salesmanName = entry['salesmanName']?.toString() ?? '-';
    final amount = _formatAmount(entry['netAmount']);

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  documentNo,
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Salesman: $salesmanName\n$customerName\nDate: $documentDate\nAmount: Rs. $amount',
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    _previewPdf(entry);
                  },
                  icon: const Icon(Icons.picture_as_pdf_rounded),
                  label: const Text('View & Share PDF'),
                  style: FilledButton.styleFrom(
                    backgroundColor: widget.accentColor,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showGrouped = _effectiveSalesmanFilter == _kAllSalesmenFilter;
    final salesmanCount = _salesmanFilterOptions.length - 1;
    final hasResults = showGrouped ? _groups.isNotEmpty : _entries.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        automaticallyImplyLeading: widget.appBarLeading == null,
        title: Text(widget.title),
        backgroundColor: widget.accentColor.withValues(alpha: 0.08),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _refreshAll,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _ReportSummaryCard(
              accentColor: widget.accentColor,
              documentCount: _summary.documentCount,
              salesmanCount: _summary.salesmanCount,
              grandTotal: _formatAmount(_summary.grandTotal),
            ),
            const SizedBox(height: 12),
            HistoryDateFilter(
              fromDate: _fromDate,
              toDate: _toDate,
              accentColor: widget.accentColor,
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
              onTap: (_isLoading || _isLoadingSalesmen) ? null : _pickSalesman,
              borderRadius: BorderRadius.circular(12),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Salesman filter (gen_salesman)',
                  prefixIcon: Icon(
                    Icons.person_search_rounded,
                    color: widget.accentColor,
                  ),
                  suffixIcon: _isLoadingSalesmen
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: widget.accentColor,
                            ),
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
                      ? 'Loading salesmen from database...'
                      : '${_salesmanFilterLabel}${salesmanCount > 0 ? ' · $salesmanCount salesmen' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Search in database',
                hintText: 'Document, customer, or salesman',
                prefixIcon: Icon(widget.icon, color: widget.accentColor),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? _ErrorState(message: _error!, onRetry: _refreshAll)
                  : !hasResults
                  ? _EmptyState(message: widget.emptyMessage)
                  : RefreshIndicator(
                      onRefresh: _refreshAll,
                      child: showGrouped
                          ? _buildGroupedList(theme)
                          : _buildFlatList(theme),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupedList(ThemeData theme) {
    return ListView.separated(
      itemCount: _groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final group = _groups[index];
        final groupKey = group.salesmanCode.isNotEmpty
            ? group.salesmanCode
            : group.salesmanName;
        final isExpanded = _expandedGroups.contains(groupKey);

        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              InkWell(
                onTap: () {
                  setState(() {
                    if (isExpanded) {
                      _expandedGroups.remove(groupKey);
                    } else {
                      _expandedGroups.add(groupKey);
                    }
                  });
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: widget.accentColor.withValues(alpha: 0.08),
                    border: Border(
                      left: BorderSide(color: widget.accentColor, width: 4),
                    ),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: widget.accentColor.withValues(
                          alpha: 0.15,
                        ),
                        child: Icon(
                          Icons.person_rounded,
                          color: widget.accentColor,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              group.salesmanName,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              'Code: ${group.salesmanCode.isEmpty ? '-' : group.salesmanCode}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${group.documentCount} doc(s)',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: widget.accentColor,
                            ),
                          ),
                          Text(
                            'Rs. ${_formatAmount(group.totalAmount)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      Icon(
                        isExpanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                      ),
                    ],
                  ),
                ),
              ),
              if (isExpanded)
                ...group.entries.map(
                  (entry) => _DocumentRow(
                    entry: entry,
                    theme: theme,
                    accentColor: widget.accentColor,
                    icon: widget.icon,
                    busyDocumentNo: _busyDocumentNo,
                    formatAmount: _formatAmount,
                    onTap: () => _showDocumentActions(entry),
                    onPreviewPdf: () => _previewPdf(entry),
                    showSalesman: false,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFlatList(ThemeData theme) {
    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return _DocumentRow(
          entry: entry,
          theme: theme,
          accentColor: widget.accentColor,
          icon: widget.icon,
          busyDocumentNo: _busyDocumentNo,
          formatAmount: _formatAmount,
          onTap: () => _showDocumentActions(entry),
          onPreviewPdf: () => _previewPdf(entry),
          showSalesman: true,
        );
      },
    );
  }
}

class _ReportSummaryCard extends StatelessWidget {
  const _ReportSummaryCard({
    required this.accentColor,
    required this.documentCount,
    required this.salesmanCount,
    required this.grandTotal,
  });

  final Color accentColor;
  final int documentCount;
  final int salesmanCount;
  final String grandTotal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            accentColor.withValues(alpha: 0.12),
            accentColor.withValues(alpha: 0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _SummaryItem(
              label: 'Documents',
              value: '$documentCount',
              theme: theme,
            ),
          ),
          Expanded(
            child: _SummaryItem(
              label: 'Salesmen',
              value: '$salesmanCount',
              theme: theme,
            ),
          ),
          Expanded(
            child: _SummaryItem(
              label: 'Total amount',
              value: 'Rs. $grandTotal',
              theme: theme,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({
    required this.label,
    required this.value,
    required this.theme,
  });

  final String label;
  final String value;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: Colors.black54),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _DocumentRow extends StatelessWidget {
  const _DocumentRow({
    required this.entry,
    required this.theme,
    required this.accentColor,
    required this.icon,
    required this.busyDocumentNo,
    required this.formatAmount,
    required this.onTap,
    required this.onPreviewPdf,
    required this.showSalesman,
  });

  final Map<String, dynamic> entry;
  final ThemeData theme;
  final Color accentColor;
  final IconData icon;
  final String? busyDocumentNo;
  final String Function(dynamic value) formatAmount;
  final VoidCallback onTap;
  final VoidCallback onPreviewPdf;
  final bool showSalesman;

  @override
  Widget build(BuildContext context) {
    final documentNo = entry['documentNo']?.toString() ?? '-';
    final customerName =
        entry['customerName']?.toString() ??
        entry['customerCode']?.toString() ??
        'Customer';
    final documentDate = entry['documentDate']?.toString() ?? '-';
    final salesmanName = entry['salesmanName']?.toString() ?? '-';
    final isBusy = busyDocumentNo == documentNo;

    return ListTile(
      onTap: onTap,
      tileColor: Colors.white,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: Color(0x14000000)),
      ),
      leading: CircleAvatar(
        backgroundColor: accentColor.withValues(alpha: 0.12),
        child: Icon(icon, color: accentColor, size: 20),
      ),
      title: Text(
        documentNo,
        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        showSalesman
            ? '$salesmanName · $customerName\nDate: $documentDate · Rs. ${formatAmount(entry['netAmount'])}'
            : '$customerName\nDate: $documentDate · Rs. ${formatAmount(entry['netAmount'])}',
      ),
      isThreeLine: true,
      trailing: isBusy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              tooltip: 'View & Share PDF',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              icon: Icon(Icons.picture_as_pdf_rounded, color: accentColor, size: 22),
              onPressed: onPreviewPdf,
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: Colors.black54,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
