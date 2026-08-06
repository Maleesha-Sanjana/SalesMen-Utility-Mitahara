import 'package:flutter/material.dart';

class InvoiceRecallDialog extends StatefulWidget {
  const InvoiceRecallDialog({
    super.key,
    required this.customerName,
    required this.invoices,
    required this.accentColor,
    this.documentLabel = 'Invoice',
    this.searchHint = 'Search by invoice number',
    this.emptyText = 'No invoices found',
    this.icon = Icons.receipt_long_rounded,
  });

  final String customerName;
  final List<Map<String, String>> invoices;
  final Color accentColor;
  final String documentLabel;
  final String searchHint;
  final String emptyText;
  final IconData icon;

  @override
  State<InvoiceRecallDialog> createState() => _InvoiceRecallDialogState();
}

class _InvoiceRecallDialogState extends State<InvoiceRecallDialog> {
  late final TextEditingController _searchController;
  late List<Map<String, String>> _filteredInvoices;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _filteredInvoices = List.from(widget.invoices);
    _searchController.addListener(_handleSearchChanged);
  }

  void _handleSearchChanged() {
    _applyFilter(_searchController.text);
  }

  void _applyFilter(String query) {
    final lowerQuery = query.trim().toLowerCase();
    setState(() {
      if (lowerQuery.isEmpty) {
        _filteredInvoices = List.from(widget.invoices);
        return;
      }

      _filteredInvoices = widget.invoices.where((invoice) {
        final invoiceNo = invoice['id']?.toLowerCase() ?? '';
        return invoiceNo.contains(lowerQuery);
      }).toList();
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_handleSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final keyboardOpen = media.viewInsets.bottom > 0;
    final availableHeight = media.size.height - media.viewInsets.bottom - 160;
    double dialogHeight;

    if (availableHeight.isFinite && availableHeight > 0) {
      dialogHeight = availableHeight;
      if (dialogHeight > 480.0) dialogHeight = 480.0;
      final minHeight = keyboardOpen ? 220.0 : 260.0;
      if (dialogHeight < minHeight) dialogHeight = minHeight;
    } else {
      dialogHeight = media.size.height * 0.6;
    }

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text('Select ${widget.documentLabel} — ${widget.customerName}'),
      content: SizedBox(
        width: double.maxFinite,
        height: dialogHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: widget.searchHint,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _filteredInvoices.isEmpty
                  ? Center(child: Text(widget.emptyText))
                  : ListView.separated(
                      itemCount: _filteredInvoices.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final invoice = _filteredInvoices[index];
                        final id = invoice['id'] ?? '';
                        final date = invoice['date'] ?? '';
                        final amount = invoice['amount'] ?? '';
                        return ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: theme.colorScheme.outline.withOpacity(0.2),
                            ),
                          ),
                          leading: CircleAvatar(
                            backgroundColor:
                                widget.accentColor.withOpacity(0.12),
                            foregroundColor: widget.accentColor,
                            child: Icon(widget.icon),
                          ),
                          title: Text(id),
                          subtitle: Text('$date • $amount'),
                          onTap: () {
                            FocusScope.of(context).unfocus();
                            Navigator.of(context).pop(invoice);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(<String, String>{}),
          child: const Text('Clear'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
