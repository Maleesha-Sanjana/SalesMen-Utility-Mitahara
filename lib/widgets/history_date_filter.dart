import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class HistoryDateFilter extends StatelessWidget {
  const HistoryDateFilter({
    super.key,
    required this.fromDate,
    required this.toDate,
    required this.onFromDateChanged,
    required this.onToDateChanged,
    required this.onClear,
    this.accentColor = const Color(0xFF598DC9),
  });

  final DateTime? fromDate;
  final DateTime? toDate;
  final ValueChanged<DateTime?> onFromDateChanged;
  final ValueChanged<DateTime?> onToDateChanged;
  final VoidCallback onClear;
  final Color accentColor;

  static final _displayFormat = DateFormat('dd MMM yyyy');
  static final _apiFormat = DateFormat('yyyy-MM-dd');

  static String? toApiDate(DateTime? date) {
    if (date == null) return null;
    return _apiFormat.format(date);
  }

  Future<void> _pickDate(
    BuildContext context, {
    required DateTime? initial,
    required DateTime? min,
    required DateTime? max,
    required ValueChanged<DateTime?> onChanged,
  }) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initial ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: 'Select date',
    );
    if (picked != null) {
      onChanged(DateTime(picked.year, picked.month, picked.day));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasFilter = fromDate != null || toDate != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickDate(
                  context,
                  initial: fromDate ?? toDate,
                  min: null,
                  max: toDate,
                  onChanged: onFromDateChanged,
                ),
                icon: Icon(Icons.date_range, color: accentColor, size: 18),
                label: Text(
                  fromDate == null
                      ? 'From date'
                      : _displayFormat.format(fromDate!),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickDate(
                  context,
                  initial: toDate ?? fromDate,
                  min: fromDate,
                  max: null,
                  onChanged: onToDateChanged,
                ),
                icon: Icon(Icons.event, color: accentColor, size: 18),
                label: Text(
                  toDate == null ? 'To date' : _displayFormat.format(toDate!),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (hasFilter) ...[
              const SizedBox(width: 8),
              IconButton(
                onPressed: onClear,
                tooltip: 'Clear dates',
                icon: const Icon(Icons.clear),
              ),
            ],
          ],
        ),
        if (hasFilter)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Showing records'
              '${fromDate != null ? ' from ${_displayFormat.format(fromDate!)}' : ''}'
              '${toDate != null ? ' to ${_displayFormat.format(toDate!)}' : ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.black54,
              ),
            ),
          ),
      ],
    );
  }
}
