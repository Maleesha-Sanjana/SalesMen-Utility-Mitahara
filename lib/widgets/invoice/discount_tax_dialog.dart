import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Discount & Tax Dialog Widget
/// 
/// Allows users to set discount (percentage or flat amount) and tax type for invoices.
/// Shows a preview of the calculated totals before applying.
class DiscountTaxDialog extends StatelessWidget {
  const DiscountTaxDialog({
    super.key,
    required this.initialDiscount,
    required this.initialIsPercentageDiscount,
    required this.initialSelectedTax,
    required this.onApply,
    required this.calculateSubTotal,
    required this.buildSummaryRow,
  });

  final double initialDiscount;
  final bool initialIsPercentageDiscount;
  final String? initialSelectedTax;
  final void Function({
    required double discount,
    required bool isPercentageDiscount,
    required String? selectedTax,
  }) onApply;
  final double Function() calculateSubTotal;
  final Widget Function(String label, double amount, ThemeData theme, {bool isDiscount, bool isTotal}) buildSummaryRow;

  @override
  Widget build(BuildContext context) {
    return _DiscountTaxDialogContent(
      initialDiscount: initialDiscount,
      initialIsPercentageDiscount: initialIsPercentageDiscount,
      initialSelectedTax: initialSelectedTax,
      onApply: onApply,
      calculateSubTotal: calculateSubTotal,
      buildSummaryRow: buildSummaryRow,
    );
  }
}

class _DiscountTaxDialogContent extends StatefulWidget {
  const _DiscountTaxDialogContent({
    required this.initialDiscount,
    required this.initialIsPercentageDiscount,
    required this.initialSelectedTax,
    required this.onApply,
    required this.calculateSubTotal,
    required this.buildSummaryRow,
  });

  final double initialDiscount;
  final bool initialIsPercentageDiscount;
  final String? initialSelectedTax;
  final void Function({
    required double discount,
    required bool isPercentageDiscount,
    required String? selectedTax,
  }) onApply;
  final double Function() calculateSubTotal;
  final Widget Function(String label, double amount, ThemeData theme, {bool isDiscount, bool isTotal}) buildSummaryRow;

  @override
  State<_DiscountTaxDialogContent> createState() => _DiscountTaxDialogContentState();
}

class _DiscountTaxDialogContentState extends State<_DiscountTaxDialogContent> {
  late final TextEditingController discountCtrl;
  late bool percentageDiscountState;
  late String? selectedTaxState;

  @override
  void initState() {
    super.initState();
    discountCtrl = TextEditingController(text: widget.initialDiscount.toString());
    percentageDiscountState = widget.initialIsPercentageDiscount;
    selectedTaxState = widget.initialSelectedTax;
  }

  @override
  void dispose() {
    discountCtrl.dispose();
    super.dispose();
  }

  Future<void> _openDiscountEntry() async {
    final tempController = TextEditingController(text: discountCtrl.text);
    final theme = Theme.of(context);
    final result = await showDialog<String?>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            percentageDiscountState
                ? 'Enter Discount (%)'
                : 'Enter Discount (Rs.)',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                percentageDiscountState
                    ? 'Enter the discount percentage (0-100)'
                    : 'Enter the flat discount amount',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: tempController,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: percentageDiscountState
                      ? 'Discount Percentage'
                      : 'Discount Amount',
                  hintText: percentageDiscountState ? 'e.g., 10' : 'e.g., 500.00',
                  suffixText: percentageDiscountState ? '%' : 'Rs.',
                  border: const OutlineInputBorder(),
                  prefixIcon: Icon(
                    percentageDiscountState
                        ? Icons.percent_rounded
                        : Icons.currency_rupee_rounded,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(tempController.text.trim());
              },
              child: const Text('Set'),
            ),
          ],
        );
      },
    );

    if (result != null && mounted) {
      final parsedValue = double.tryParse(result);
      if (parsedValue != null) {
        if (percentageDiscountState && parsedValue > 100) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Percentage discount cannot exceed 100%'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
        setState(() {
          discountCtrl.text = parsedValue.toStringAsFixed(2);
        });
      }
    }
  }

  void _handleApply() {
    final theme = Theme.of(context);
    final discount = discountCtrl.text.trim().isEmpty
        ? 0.0
        : double.tryParse(discountCtrl.text.trim()) ?? 0.0;

    // Calculate values for preview
    final subtotal = widget.calculateSubTotal();
    final billDiscountAmount = percentageDiscountState
        ? subtotal * (discount / 100)
        : discount;
    final discountedTotal = (subtotal - billDiscountAmount).clamp(0, double.infinity);
    
    // Calculate tax (matching _calculateTotal logic)
    double taxAmount = 0.0;
    if (selectedTaxState != null && selectedTaxState!.isNotEmpty) {
      double taxRate = 0.15; // Default VAT rate
      if (selectedTaxState!.contains('NBT 1')) {
        taxRate = 0.02; // NBT 1% + VAT 15% = approximate
      } else if (selectedTaxState!.contains('NBT 2')) {
        taxRate = 0.02; // NBT 2% + VAT 15% = approximate
      } else if (selectedTaxState == 'VAT') {
        taxRate = 0.15; // VAT only
      }
      taxAmount = discountedTotal * taxRate;
    }
    final grandTotal = discountedTotal + taxAmount;

    // Show preview dialog
    showDialog(
      context: context,
      builder: (previewContext) {
        return AlertDialog(
          title: const Text('Bill Summary'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              widget.buildSummaryRow('Full Bill', subtotal, theme),
              const SizedBox(height: 12),
              widget.buildSummaryRow(
                'Discount ${percentageDiscountState ? '($discount%)' : ''}',
                -billDiscountAmount,
                theme,
                isDiscount: true,
              ),
              const SizedBox(height: 12),
              if (selectedTaxState != null && selectedTaxState!.isNotEmpty)
                widget.buildSummaryRow(
                  'Tax (${selectedTaxState})',
                  taxAmount,
                  theme,
                ),
              if (selectedTaxState != null && selectedTaxState!.isNotEmpty)
                const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 12),
              widget.buildSummaryRow('Grand Total', grandTotal, theme, isTotal: true),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(previewContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(previewContext).pop();
                widget.onApply(
                  discount: discount,
                  isPercentageDiscount: percentageDiscountState,
                  selectedTax: selectedTaxState,
                );
                if (context.mounted) {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Applied: Discount ${percentageDiscountState ? '%' : 'Rs'} $discount • Tax: ${selectedTaxState ?? 'None'}',
                      ),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return AlertDialog(
      title: const Text('Discount & Taxes'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Discount Type Segmented Button
          Text(
            'Discount Type',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(
                value: true,
                label: Text('%'),
                icon: Icon(Icons.percent_rounded, size: 18),
              ),
              ButtonSegment<bool>(
                value: false,
                label: Text('Rs.'),
                icon: Icon(Icons.currency_rupee_rounded, size: 18),
              ),
            ],
            selected: {percentageDiscountState},
            onSelectionChanged: (Set<bool> newSelection) {
              setState(() {
                percentageDiscountState = newSelection.first;
              });
            },
            style: SegmentedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
          const SizedBox(height: 20),
          // Discount Entry Field
          Text(
            percentageDiscountState
                ? 'Discount (%)'
                : 'Discount (Rs.)',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: discountCtrl,
            readOnly: true,
            onTap: _openDiscountEntry,
            decoration: InputDecoration(
              labelText: percentageDiscountState
                  ? 'Percentage Discount'
                  : 'Flat Amount Discount',
              hintText: percentageDiscountState
                  ? 'Tap to enter percentage (0-100)'
                  : 'Tap to enter amount',
              suffixText: percentageDiscountState ? '%' : 'Rs.',
              prefixIcon: const Icon(Icons.edit_rounded),
              suffixIcon: const Icon(Icons.edit_rounded),
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 16),
          // Tax Dropdown
          DropdownButtonFormField<String>(
            value: selectedTaxState,
            decoration: const InputDecoration(
              labelText: 'Select Tax Type',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                vertical: 8,
                horizontal: 12,
              ),
              isDense: true,
            ),
            items: const [
              'NBT 1 & VAT',
              'NBT 2 & VAT',
              'VAT',
              'NBT, VAT',
              'NBT 1, VAT',
            ].map((String tax) {
              return DropdownMenuItem<String>(
                value: tax,
                child: Text(tax),
              );
            }).toList(),
            onChanged: (String? value) {
              setState(() {
                selectedTaxState = value;
              });
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
          ),
          onPressed: _handleApply,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

