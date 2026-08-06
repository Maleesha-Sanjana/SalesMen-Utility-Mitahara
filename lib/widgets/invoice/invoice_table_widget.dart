import 'package:flutter/material.dart';

class InvoiceTableWidget extends StatelessWidget {
  const InvoiceTableWidget({
    super.key,
    required this.rows,
    required this.onRemoveItem,
    required this.onChangeQuantity,
    required this.getPriceFromRow,
    required this.calculateSubTotal,
    required this.invoiceDiscount,
    required this.isPercentageDiscount,
    required this.shortItemLabel,
    required this.accentColor,
  });

  final List<Map<String, dynamic>> rows;
  final void Function(int index) onRemoveItem;
  final void Function(int index, int delta) onChangeQuantity;
  final double Function(Map<String, dynamic>) getPriceFromRow;
  final double Function() calculateSubTotal;
  final double invoiceDiscount;
  final bool isPercentageDiscount;
  final String Function(String?) shortItemLabel;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 16,
              dataRowMinHeight: 48,
              dataRowMaxHeight: 72,
              columns: [
                const DataColumn(label: Text('Item')),
                const DataColumn(label: Text('Item Name')),
                const DataColumn(label: Text('Qty'), numeric: true),
                const DataColumn(label: Text('Free'), numeric: true),
                const DataColumn(label: Text('Disc ( Rs. )')),
                const DataColumn(
                  label: Text('Price (Rs.)'),
                  numeric: true,
                ),
                const DataColumn(
                  label: Text('Subtotal (Rs.)'),
                  numeric: true,
                ),
                const DataColumn(
                  label: Text('Discount (Rs.)'),
                  numeric: true,
                ),
                const DataColumn(
                  label: Text('Total (Rs.)'),
                  numeric: true,
                ),
                DataColumn(
                  label: SizedBox(
                    width: 168,
                    child: Center(
                      child: Text(
                        'Action',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                  numeric: false,
                ),
              ],
              rows: () {
                final totalItemsNet = calculateSubTotal();
                final billDiscountAmount = invoiceDiscount > 0
                    ? (isPercentageDiscount
                          ? totalItemsNet * (invoiceDiscount / 100)
                          : invoiceDiscount)
                    : 0.0;

                return rows.asMap().entries.map((entry) {
                  final index = entry.key;
                  final r = entry.value;
                  final price = getPriceFromRow(r);
                  final qty = (r['qty'] as num?)?.toInt() ?? 1;
                  final itemSubtotal = price * qty;

                  final discountStr =
                      (r['discount'] as String?)?.replaceAll(
                        RegExp(r'[^0-9.]'),
                        '',
                      ) ??
                      '0';
                  final discountValue = double.tryParse(discountStr) ?? 0.0;
                  final isItemDiscountPercent =
                      (r['discount'] as String?)?.contains('%') ?? false;
                  final itemDiscountAmount = isItemDiscountPercent
                      ? itemSubtotal * (discountValue / 100)
                      : discountValue;

                  final itemNetAfterDiscount = itemSubtotal - itemDiscountAmount;

                  double combinedDiscountAmount = itemDiscountAmount;
                  if (billDiscountAmount > 0 && totalItemsNet > 0) {
                    final itemProportion = itemNetAfterDiscount / totalItemsNet;
                    final itemBillDiscountPortion =
                        billDiscountAmount * itemProportion;
                    combinedDiscountAmount =
                        itemDiscountAmount + itemBillDiscountPortion;
                  }

                  final itemFinalTotal = itemSubtotal - combinedDiscountAmount;

                  return DataRow(
                    cells: [
                      DataCell(
                        Text(
                          shortItemLabel(r['item'] as String?),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DataCell(
                        Text(
                          r['item']?.toString().split('•').last.trim() ?? '',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DataCell(
                        Text('${r['qty']}', textAlign: TextAlign.end),
                      ),
                      DataCell(
                        Text(
                          '${r['freeQty'] ?? 0}',
                          textAlign: TextAlign.end,
                        ),
                      ),
                      DataCell(
                        Text(
                          itemDiscountAmount.toStringAsFixed(2),
                          textAlign: TextAlign.end,
                        ),
                      ),
                      DataCell(
                        Text(
                          '${price.toStringAsFixed(2)}',
                          textAlign: TextAlign.end,
                        ),
                      ),
                      DataCell(
                        Text(
                          itemSubtotal.toStringAsFixed(2),
                          textAlign: TextAlign.end,
                        ),
                      ),
                      DataCell(
                        Text(
                          combinedDiscountAmount.toStringAsFixed(2),
                          textAlign: TextAlign.end,
                        ),
                      ),
                      DataCell(
                        Text(
                          itemFinalTotal.toStringAsFixed(2),
                          textAlign: TextAlign.end,
                        ),
                      ),
                      DataCell(
                        Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                tooltip: 'Reduce quantity',
                                onPressed: qty <= 1
                                    ? null
                                    : () => onChangeQuantity(index, -1),
                                icon: const Icon(
                                  Icons.remove_rounded,
                                  size: 28,
                                ),
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  iconSize: 28,
                                  foregroundColor: accentColor,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Increase quantity',
                                onPressed: () => onChangeQuantity(index, 1),
                                icon: const Icon(
                                  Icons.add_rounded,
                                  size: 28,
                                ),
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  iconSize: 28,
                                  foregroundColor: accentColor,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Remove item',
                                onPressed: () => onRemoveItem(index),
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 28,
                                ),
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  iconSize: 28,
                                  foregroundColor: Theme.of(
                                    context,
                                  ).colorScheme.onErrorContainer,
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.errorContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList();
              }(),
            ),
          ),
        );
      },
    );
  }
}
