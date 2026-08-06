import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/api_service.dart';

class LeaderboardPage extends StatelessWidget {
  const LeaderboardPage({super.key, this.appBarLeading, this.embedded = false});

  final Widget? appBarLeading;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    if (embedded) {
      return const LeaderboardContent();
    }

    return Scaffold(
      appBar: AppBar(
        leading:
            appBarLeading ??
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
        title: const Text('LeaderBoard'),
        backgroundColor: const Color(0xFF598DC9).withValues(alpha: 0.08),
      ),
      body: const LeaderboardContent(),
    );
  }
}

class LeaderboardContent extends StatefulWidget {
  const LeaderboardContent({super.key});

  @override
  State<LeaderboardContent> createState() => _LeaderboardContentState();
}

class _LeaderboardContentState extends State<LeaderboardContent> {
  static const Color _accentColor = Color(0xFF598DC9);

  bool _isLoading = true;
  String? _error;
  String _selectedDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
  List<Map<String, dynamic>> _entries = [];

  @override
  void initState() {
    super.initState();
    _loadLeaderboard();
  }

  Future<void> _loadLeaderboard() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await ApiService.getDailyLeaderboard(date: _selectedDate);
      if (!mounted) return;

      final entries = (result['entries'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      setState(() {
        _entries = entries;
        _selectedDate = result['date']?.toString() ?? _selectedDate;
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

  Future<void> _pickDate() async {
    final initial = DateTime.tryParse(_selectedDate) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;

    setState(() {
      _selectedDate = DateFormat('yyyy-MM-dd').format(picked);
    });
    await _loadLeaderboard();
  }

  String _rankLabel(int rank) {
    switch (rank) {
      case 1:
        return '1st';
      case 2:
        return '2nd';
      case 3:
        return '3rd';
      default:
        return '${rank}th';
    }
  }

  Color _rankColor(int rank) {
    switch (rank) {
      case 1:
        return const Color(0xFFF59E0B);
      case 2:
        return const Color(0xFF94A3B8);
      case 3:
        return const Color(0xFFCD7F32);
      default:
        return _accentColor;
    }
  }

  IconData _rankIcon(int rank) {
    switch (rank) {
      case 1:
        return Icons.emoji_events_rounded;
      case 2:
        return Icons.military_tech_rounded;
      case 3:
        return Icons.workspace_premium_rounded;
      default:
        return Icons.person_rounded;
    }
  }

  Widget _buildDateHeader(ThemeData theme, {required bool showAmounts}) {
    final displayDate =
        DateFormat('EEEE, d MMM yyyy').format(DateTime.parse(_selectedDate));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Daily LeaderBoard',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: _accentColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  displayDate,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  showAmounts
                      ? 'Ranked by Sales Order + Quotation amount'
                      : 'See who is 1st, 2nd, 3rd and more',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            onPressed: _isLoading ? null : _pickDate,
            icon: const Icon(Icons.calendar_month_rounded),
            tooltip: 'Pick date',
          ),
          IconButton(
            onPressed: _isLoading ? null : _loadLeaderboard,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }

  String _formatAmount(num value) {
    return NumberFormat.currency(
      locale: 'en_LK',
      symbol: 'Rs ',
      decimalDigits: 2,
    ).format(value);
  }

  double _amountValue(Map<String, dynamic> entry, String key) {
    final value = entry[key];
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  double _totalAmount(Map<String, dynamic> entry) {
    final total = _amountValue(entry, 'totalAmount');
    if (total > 0) return total;
    return _amountValue(entry, 'totalScore');
  }

  Widget _buildPodium(
    ThemeData theme,
    String? currentRepCode, {
    required bool showAmounts,
  }) {
    final topThree = _entries.take(3).toList();
    if (topThree.isEmpty) return const SizedBox.shrink();

    Widget buildPodiumSlot(Map<String, dynamic> entry, double height) {
      final rank = entry['rank'] as int? ?? 0;
      final name = entry['salesmanName']?.toString() ?? '-';
      final code = entry['salesmanCode']?.toString() ?? '';
      final total = _totalAmount(entry);
      final isCurrent =
          currentRepCode != null &&
          code.trim().toUpperCase() == currentRepCode.trim().toUpperCase();

      return Expanded(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (isCurrent)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _accentColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'You',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _accentColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            Icon(_rankIcon(rank), color: _rankColor(rank), size: 28),
            const SizedBox(height: 6),
            Text(
              _rankLabel(rank),
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: _rankColor(rank),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              code,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              height: height,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: _rankColor(rank).withValues(alpha: 0.18),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(12),
                ),
                border: Border.all(color: _rankColor(rank).withValues(alpha: 0.35)),
              ),
              child: Text(
                showAmounts ? _formatAmount(total) : _rankLabel(rank),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: _rankColor(rank),
                  fontSize: showAmounts ? 11 : 14,
                ),
              ),
            ),
          ],
        ),
      );
    }

    Map<String, dynamic>? first;
    Map<String, dynamic>? second;
    Map<String, dynamic>? third;
    for (final entry in topThree) {
      final rank = entry['rank'] as int? ?? 0;
      if (rank == 1) first = entry;
      if (rank == 2) second = entry;
      if (rank == 3) third = entry;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (second != null) buildPodiumSlot(second, 72),
          if (second != null && (first != null || third != null))
            const SizedBox(width: 8),
          if (first != null) buildPodiumSlot(first, 96),
          if (first != null && third != null) const SizedBox(width: 8),
          if (third != null) buildPodiumSlot(third, 56),
        ],
      ),
    );
  }

  int _registrationCount(Map<String, dynamic> entry, String key) {
    final value = entry[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Widget _buildStatChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _buildEntryTile(
    ThemeData theme,
    Map<String, dynamic> entry,
    String? currentRepCode, {
    required bool showAmounts,
  }) {
    final rank = entry['rank'] as int? ?? 0;
    final name = entry['salesmanName']?.toString() ?? '-';
    final code = entry['salesmanCode']?.toString() ?? '';
    final salesOrders = _registrationCount(entry, 'salesOrderCount');
    final quotations = _registrationCount(entry, 'quotationCount');
    final salesOrderAmount = _amountValue(entry, 'salesOrderAmount');
    final quotationAmount = _amountValue(entry, 'quotationAmount');
    final total = _totalAmount(entry);
    final isCurrent =
        currentRepCode != null &&
        code.trim().toUpperCase() == currentRepCode.trim().toUpperCase();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      elevation: isCurrent ? 2 : 0,
      color: isCurrent ? _accentColor.withValues(alpha: 0.06) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isCurrent
              ? _accentColor.withValues(alpha: 0.35)
              : theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: _rankColor(rank).withValues(alpha: 0.15),
              child: Text(
                '$rank',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: _rankColor(rank),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        _rankLabel(rank),
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: _rankColor(rank),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    code,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  if (showAmounts) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _buildStatChip(
                          'SO ($salesOrders)',
                          _formatAmount(salesOrderAmount),
                          const Color(0xFF598DC9),
                        ),
                        _buildStatChip(
                          'QUO ($quotations)',
                          _formatAmount(quotationAmount),
                          const Color(0xFF22C55E),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (showAmounts) ...[
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatAmount(total),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: _accentColor,
                    ),
                  ),
                  Text(
                    'total',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();
    final currentRepCode = auth.salesmanCode;
    final showAmounts = auth.isAdmin || auth.isSuper;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadLeaderboard,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadLeaderboard,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _buildDateHeader(theme, showAmounts: showAmounts),
          if (_entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(
                    Icons.leaderboard_rounded,
                    size: 56,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.25),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No activity recorded for this date.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            )
          else ...[
            _buildPodium(theme, currentRepCode, showAmounts: showAmounts),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'All Salesmans (${_entries.length})',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: _accentColor,
                ),
              ),
            ),
            ..._entries.map(
              (entry) => _buildEntryTile(
                theme,
                entry,
                currentRepCode,
                showAmounts: showAmounts,
              ),
            ),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }
}
