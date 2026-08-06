import 'package:flutter/material.dart';

class LocationWiseStockPage extends StatefulWidget {
  const LocationWiseStockPage({super.key});

  @override
  State<LocationWiseStockPage> createState() => _LocationWiseStockPageState();
}

class _LocationWiseStockPageState extends State<LocationWiseStockPage> {
  final _searchController = TextEditingController();
  final List<Map<String, dynamic>> _items = [
    {
      'name': 'Nadu Rice 5kg',
      'qty': 25,
      'price': 1_250.00,
      'department': 'Staples & Rice',
      'subDepartment': 'Nadu Rice',
      'category': 'Rice & Grains',
      'subCategory': 'Nadu',
      'supplier': 'Cargills',
    },
    {
      'name': 'Samba Rice 10kg',
      'qty': 0,
      'price': 3_250.00,
      'department': 'Staples & Rice',
      'subDepartment': 'Samba Rice',
      'category': 'Rice & Grains',
      'subCategory': 'Samba',
      'supplier': 'Keells',
    },
    {
      'name': 'Ceylon Black Tea 200g',
      'qty': 7,
      'price': 950.50,
      'department': 'Tea & Beverages',
      'subDepartment': 'Ceylon Tea',
      'category': 'Tea',
      'subCategory': 'Ceylon Black Tea',
      'supplier': 'Dilmah',
    },
    {
      'name': 'Coconut Milk Powder 400g',
      'qty': 120,
      'price': 845.00,
      'department': 'Coconut Products',
      'subDepartment': 'Coconut Milk',
      'category': 'Coconut Products',
      'subCategory': 'Coconut Milk Powder',
      'supplier': 'Ruhunu Foods',
    },
    {
      'name': 'Maldive Fish 100g',
      'qty': -3,
      'price': 1_299.00,
      'department': 'Canned & Dry Fish',
      'subDepartment': 'Maldive Fish',
      'category': 'Canned & Dry Fish',
      'subCategory': 'Katta Sambol',
      'supplier': 'MD (Mauby David)',
    },
    {
      'name': 'Ceylon Cinnamon Sticks 50g',
      'qty': 42,
      'price': 1_750.00,
      'department': 'Spices & Condiments',
      'subDepartment': 'Ceylon Cinnamon',
      'category': 'Spices',
      'subCategory': 'Cinnamon',
      'supplier': 'Harischandra',
    },
    {
      'name': 'Coconut Oil 1L',
      'qty': 15,
      'price': 1_150.75,
      'department': 'Coconut Products',
      'subDepartment': 'Coconut Oil',
      'category': 'Coconut Products',
      'subCategory': 'Desiccated Coconut',
      'supplier': 'Green Valley Foods',
    },
    {
      'name': 'Katta Sambol 200g',
      'qty': 0,
      'price': 280.00,
      'department': 'Sambols & Chutneys',
      'subDepartment': 'Katta Sambol',
      'category': 'Sambols & Chutneys',
      'subCategory': 'Katta Sambol',
      'supplier': 'MD (Mauby David)',
    },
    {
      'name': 'String Hopper Flour 1kg',
      'qty': 2,
      'price': 1_099.90,
      'department': 'Bakery & Flour',
      'subDepartment': 'Flour & Batters',
      'category': 'Flour & Batters',
      'subCategory': 'Surface Cleaners',
      'supplier': 'Motha',
    },
    {
      'name': 'Kithul Treacle 350ml',
      'qty': 88,
      'price': 750.00,
      'department': 'Sweets & Desserts',
      'subDepartment': 'Sweets',
      'category': 'Sweets',
      'subCategory': 'Nuts',
      'supplier': 'Maliban',
    },
  ];

  String _viewBy = 'Product Wise';
  String? _chosenFilter;
  bool _displayAll = false;
  int? _sortColumnIndex;
  bool _sortAscending = true;

  final List<String> _departments = const [
    'Staples & Rice',
    'Spices & Condiments',
    'Coconut Products',
    'Tea & Beverages',
    'Snacks & Short Eats',
    'Sweets & Desserts',
    'Bakery & Flour',
    'Canned & Dry Fish',
    'Fresh Produce',
    'Dairy & Chilled',
  ];
  final List<String> _subDepartments = const [
    'Samba Rice',
    'Nadu Rice',
    'Red Raw Rice',
    'Ceylon Cinnamon',
    'Ceylon Cloves',
    'Black Pepper',
    'Coconut Milk',
    'Coconut Oil',
    'Ceylon Tea',
    'Maldive Fish',
  ];
  final List<String> _categories = const [
    'Rice & Grains',
    'Spices',
    'Coconut Products',
    'Tea',
    'Curry Pastes & Mixes',
    'Flour & Batters',
    'Snacks',
    'Sweets',
    'Sambols & Chutneys',
    'Canned & Dry Fish',
  ];
  final List<String> _subCategories = const [
    'Nadu',
    'Samba',
    'Red Raw',
    'Cinnamon',
    'Cardamom',
    'Cloves',
    'Coconut Milk Powder',
    'Desiccated Coconut',
    'Ceylon Black Tea',
    'Katta Sambol',
  ];
  final List<String> _suppliers = const [
    'Cargills',
    'Keells',
    'Harischandra',
    'Ruhunu Foods',
    'MD (Mauby David)',
    'Motha',
    'Dilmah',
    'Maliban',
    'Munchee',
    'Lanka Sathosa',
  ];

  // Location selector state
  final List<String> _locations = const [
    'All Locations',
    'My Location',
    'Colombo',
    'Badulla',
    'Anuradhanapura',
    'Jaffna',
    'Maleesha',
  ];
  String _selectedLocation = 'All Locations';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _formatLkrPlain(num value) {
    final negative = value < 0;
    final absVal = value.abs();
    final whole = absVal.floor();
    final frac = ((absVal - whole) * 100).round();
    String wholeStr = whole.toString();
    final buf = StringBuffer();
    for (int i = 0; i < wholeStr.length; i++) {
      final idxFromRight = wholeStr.length - i;
      buf.write(wholeStr[i]);
      if (idxFromRight > 1 && idxFromRight % 3 == 1) {
        buf.write(',');
      }
    }
    final formattedWhole = buf.toString();
    final formattedFrac = frac.toString().padLeft(2, '0');
    return '${negative ? '-' : ''}$formattedWhole.$formattedFrac';
  }

  void _showLocationPicker() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Select Location', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            ..._locations.map((loc) => ListTile(
                  title: Text(loc),
                  trailing: loc == _selectedLocation ? const Icon(Icons.check, color: Colors.green) : null,
                  onTap: () {
                    setState(() => _selectedLocation = loc);
                    Navigator.pop(context);
                  },
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildAdaptiveSearch() {
    List<String> dataset;
    String label;
    switch (_viewBy) {
      case 'Department Wise':
        dataset = _departments;
        label = 'Search Departments';
        break;
      case 'Sub-Department Wise':
        dataset = _subDepartments;
        label = 'Search Sub Departments';
        break;
      case 'Category Wise':
        dataset = _categories;
        label = 'Search Categories';
        break;
      case 'Sub Category Wise':
        dataset = _subCategories;
        label = 'Search Sub Categories';
        break;
      case 'Supplier Wise':
        dataset = _suppliers;
        label = 'Search Suppliers';
        break;
      default:
        dataset = _items.map((e) => e['name'] as String).toList();
        label = 'Search Products';
    }

    return Autocomplete<String>(
      optionsBuilder: (TextEditingValue tev) {
        final q = tev.text.trim().toLowerCase();
        if (q.isEmpty) return const Iterable<String>.empty();
        return dataset.where((e) => e.toLowerCase().contains(q));
      },
      onSelected: (val) {
        _searchController.text = val;
        setState(() {});
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        controller.text = _searchController.text;
        controller.selection = _searchController.selection;
        controller.addListener(() {
          if (controller.text != _searchController.text) {
            _searchController.value = controller.value;
            setState(() {});
          }
        });
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: label,
            prefixIcon: const Icon(Icons.search),
          ),
          onSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, minWidth: 280),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final opt = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    title: Text(opt),
                    onTap: () => onSelected(opt),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void _showViewBy() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        Widget option(String label, IconData icon) => ListTile(
              leading: Icon(icon),
              title: Text(label),
              onTap: () {
                setState(() {
                  _viewBy = label;
                  _chosenFilter = null;
                });
                Navigator.pop(context);
              },
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('View By', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                ),
                option('Product Wise', Icons.inventory_2_rounded),
                option('Department Wise', Icons.apartment_rounded),
                option('Sub-Department Wise', Icons.account_tree_rounded),
                option('Category Wise', Icons.category_rounded),
                option('Sub Category Wise', Icons.dashboard_customize_rounded),
                option('Supplier Wise', Icons.local_shipping_rounded),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSelectionPicker(String title, List<String> options) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
              ...options.map((e) => ListTile(
                    title: Text(e),
                    onTap: () {
                      setState(() => _chosenFilter = e);
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Selected: $e')));
                    },
                  )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _searchController.text.trim().toLowerCase();
    final filtered = _items.where((e) {
      final nameMatch = _viewBy == 'Product Wise' ? (q.isEmpty || (e['name'] as String).toLowerCase().contains(q)) : true;
      final qty = e['qty'] as int;
      final stockMatch = _displayAll ? true : qty > 0;
      return nameMatch && stockMatch;
    }).toList();

    int compareName(a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase());
    int compareQty(a, b) => (a['qty'] as num).compareTo(b['qty'] as num);
    int comparePrice(a, b) => ((a['price'] as num?) ?? 0).compareTo(((b['price'] as num?) ?? 0));
    if (_sortColumnIndex != null) {
      switch (_sortColumnIndex) {
        case 0:
          filtered.sort(compareName);
          break;
        case 1:
          filtered.sort(compareQty);
          break;
        case 2:
          filtered.sort(comparePrice);
          break;
      }
      if (!_sortAscending) {
        filtered.setAll(0, filtered.reversed);
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Location Wise Stock')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _displayAll,
                      visualDensity: VisualDensity.compact,
                      onChanged: (v) => setState(() => _displayAll = v ?? false),
                    ),
                    const SizedBox(width: 6),
                    const Text('Display All'),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _showLocationPicker,
                      icon: const Icon(Icons.place_outlined, size: 18),
                      label: Text(_selectedLocation),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        minimumSize: const Size(0, 0),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _showViewBy,
                    icon: const Icon(Icons.tune),
                    label: Text(_viewBy, textAlign: TextAlign.justify),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _viewBy == 'Product Wise'
                        ? null
                        : () {
                            switch (_viewBy) {
                              case 'Department Wise':
                                _showSelectionPicker('Main Departments', _departments);
                                break;
                              case 'Sub-Department Wise':
                                _showSelectionPicker('Sub Departments', _subDepartments);
                                break;
                              case 'Category Wise':
                                _showSelectionPicker('Main Categories', _categories);
                                break;
                              case 'Sub Category Wise':
                                _showSelectionPicker('Sub Categories', _subCategories);
                                break;
                              case 'Supplier Wise':
                                _showSelectionPicker('Main Suppliers', _suppliers);
                                break;
                            }
                          },
                    icon: const Icon(Icons.list_alt),
                    label: Text(() {
                      switch (_viewBy) {
                        case 'Department Wise':
                          return _chosenFilter == null ? 'Main Departments' : _chosenFilter!;
                        case 'Sub-Department Wise':
                          return _chosenFilter == null ? 'Sub Departments' : _chosenFilter!;
                        case 'Category Wise':
                          return _chosenFilter == null ? 'Main Categories' : _chosenFilter!;
                        case 'Sub Category Wise':
                          return _chosenFilter == null ? 'Sub Categories' : _chosenFilter!;
                        case 'Supplier Wise':
                          return _chosenFilter == null ? 'Main Suppliers' : _chosenFilter!;
                        default:
                          return 'Select';
                      }
                    }(), textAlign: TextAlign.justify),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildAdaptiveSearch(),
            const SizedBox(height: 16),
            Expanded(
              child: Card(
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: LayoutBuilder(
                    builder: (context, box) {
                      const double hMargin = 4;
                      const double colSpacing = 12;
                      const double stockW = 56;
                      const double priceW = 84;
                      final double available = box.maxWidth - (hMargin * 2) - (colSpacing * 2) - stockW - priceW;
                      final double itemW = available.clamp(120.0, box.maxWidth);

                      return Scrollbar(
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.vertical,
                          child: DataTable(
                            columnSpacing: colSpacing,
                            headingRowHeight: 40,
                            dataRowMinHeight: 38,
                            dataRowMaxHeight: 46,
                            columns: [
                              DataColumn(
                                label: const Text('Item'),
                                onSort: (col, asc) => setState(() {
                                  _sortColumnIndex = col;
                                  _sortAscending = asc;
                                }),
                              ),
                              DataColumn(
                                numeric: true,
                                label: const Text('Stock'),
                                onSort: (col, asc) => setState(() {
                                  _sortColumnIndex = col;
                                  _sortAscending = asc;
                                }),
                              ),
                              DataColumn(
                                numeric: true,
                                label: const Text('Price (Rs.)'),
                                onSort: (col, asc) => setState(() {
                                  _sortColumnIndex = col;
                                  _sortAscending = asc;
                                }),
                              ),
                            ],
                            rows: _buildGroupedRows(
                              context: context,
                              theme: theme,
                              rows: filtered,
                              itemW: itemW,
                              stockW: stockW,
                              priceW: priceW,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<DataRow> _buildGroupedRows({
    required BuildContext context,
    required ThemeData theme,
    required List<Map<String, dynamic>> rows,
    required double itemW,
    required double stockW,
    required double priceW,
  }) {
    String trunc(String text, double width) {
      final maxChars = (width / 7).floor().clamp(6, 120);
      if (text.length > maxChars) {
        return text.substring(0, (maxChars - 5).clamp(0, text.length)) + '.....';
      }
      return text;
    }

    final mode = _viewBy;
    final selected = _chosenFilter;

    DataRow headerRow(String title) => DataRow(
          color: MaterialStateProperty.resolveWith((_) => theme.colorScheme.primary.withOpacity(0.06)),
          cells: [
            DataCell(SizedBox(width: itemW, child: Text(title, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w700)))),
            const DataCell(Text('')),
            const DataCell(Text('')),
          ],
        );

    DataRow productRow(Map<String, dynamic> it, int index) {
      final qty = (it['qty'] as num?)?.toInt() ?? 0;
      final price = (it['price'] as num?) ?? 0;
      final inStock = qty > 0;
      final name = (it['name'] as String?) ?? '';
      return DataRow(
        color: MaterialStateProperty.resolveWith((_) => index.isEven ? theme.colorScheme.surface : theme.colorScheme.surfaceVariant.withOpacity(0.3)),
        cells: [
          DataCell(SizedBox(width: itemW, child: Text(trunc(name, itemW), maxLines: 1))),
          DataCell(SizedBox(
            width: stockW,
            child: Align(alignment: Alignment.centerRight, child: Text('$qty', style: TextStyle(color: inStock ? theme.colorScheme.onSurface : const Color(0xFFEF4444)))),
          )),
          DataCell(SizedBox(width: priceW, child: Align(alignment: Alignment.centerRight, child: Text(_formatLkrPlain(price))))),
        ],
      );
    }

    final List<DataRow> out = [];

    if (mode == 'Product Wise') {
      for (var i = 0; i < rows.length; i++) {
        out.add(productRow(rows[i], i));
      }
      return out;
    }

    void groupByKey(String key) {
      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final it in rows) {
        final k = (it[key] as String?) ?? 'Unknown';
        if (selected?.isNotEmpty == true && selected != k) continue;
        grouped.putIfAbsent(k, () => []).add(it);
      }
      final sortedKeys = grouped.keys.toList()..sort();
      for (final k in sortedKeys) {
        out.add(headerRow(k));
        final list = grouped[k]!;
        for (var i = 0; i < list.length; i++) {
          out.add(productRow(list[i], i));
        }
      }
    }

    void groupByTwo(String parentKey, String childKey) {
      final parents = <String, List<Map<String, dynamic>>>{};
      for (final it in rows) {
        final pk = (it[parentKey] as String?) ?? 'Unknown';
        parents.putIfAbsent(pk, () => []).add(it);
      }
      final sortedParents = parents.keys.toList()..sort();
      for (final pk in sortedParents) {
        if (selected?.isNotEmpty == true && selected != pk) continue;
        out.add(headerRow(pk));
        final children = <String, List<Map<String, dynamic>>>{};
        for (final it in parents[pk]!) {
          final ck = (it[childKey] as String?) ?? 'Unknown';
          children.putIfAbsent(ck, () => []).add(it);
        }
        final sortedChildren = children.keys.toList()..sort();
        for (final ck in sortedChildren) {
          out.add(headerRow('  • $ck'));
          final list = children[ck]!;
          for (var i = 0; i < list.length; i++) {
            out.add(productRow(list[i], i));
          }
        }
      }
    }

    switch (mode) {
      case 'Department Wise':
        groupByKey('department');
        break;
      case 'Sub-Department Wise':
        groupByTwo('department', 'subDepartment');
        break;
      case 'Category Wise':
        groupByKey('category');
        break;
      case 'Sub Category Wise':
        groupByTwo('category', 'subCategory');
        break;
      case 'Supplier Wise':
        groupByKey('supplier');
        break;
      default:
        for (var i = 0; i < rows.length; i++) {
          out.add(productRow(rows[i], i));
        }
    }

    return out;
  }
}
