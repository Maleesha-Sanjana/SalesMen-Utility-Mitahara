import 'package:flutter/material.dart';

/// Invoice Summary Widget
///
/// Displays the financial summary of an invoice including:
/// - Subtotal
/// - Discount (if applicable)
/// - Tax (if applicable)
/// - Total
class InvoiceSummaryWidget extends StatelessWidget {
  const InvoiceSummaryWidget({
    super.key,
    required this.subtotal,
    required this.billDiscountAmount,
    required this.taxAmount,
    required this.netAmount,
    this.invoiceDiscount = 0.0,
    this.isPercentageDiscount = true,
    this.selectedTax,
  });

  final double subtotal;
  final double billDiscountAmount;
  final double taxAmount;
  final double netAmount;
  final double invoiceDiscount;
  final bool isPercentageDiscount;
  final String? selectedTax;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSummaryRow(context, 'Subtotal:', subtotal, theme),
          if (billDiscountAmount > 0) ...[
            const SizedBox(height: 8),
            _buildSummaryRow(
              context,
              'Discount ${isPercentageDiscount ? '($invoiceDiscount%)' : ''}:',
              -billDiscountAmount,
              theme,
              isDiscount: true,
            ),
          ],
          if (taxAmount > 0 && selectedTax != null) ...[
            const SizedBox(height: 8),
            _buildSummaryRow(
              context,
              'Tax (${selectedTax ?? ''}):',
              taxAmount,
              theme,
            ),
          ],
          const Divider(height: 24),
          _buildSummaryRow(context, 'Total:', netAmount, theme, isTotal: true),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(
    BuildContext context,
    String label,
    double amount,
    ThemeData theme, {
    bool isDiscount = false,
    bool isTotal = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: isTotal
              ? theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                )
              : theme.textTheme.bodyMedium,
        ),
        Text(
          isDiscount
              ? '-Rs ${amount.abs().toStringAsFixed(2)}'
              : 'Rs ${amount.toStringAsFixed(2)}',
          style: isTotal
              ? theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                )
              : theme.textTheme.bodyMedium?.copyWith(
                  color: isDiscount ? theme.colorScheme.error : null,
                ),
        ),
      ],
    );
  }
}
