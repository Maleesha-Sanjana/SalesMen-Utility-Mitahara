import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/cart_provider.dart';
import '../providers/auth_provider.dart';
import '../services/sales_order_pdf_generator.dart';
import '../services/quotation_pdf_generator.dart';
import '../services/receipt_pdf_generator.dart';
import '../services/pdf_preview_service.dart';
import '../services/bluetooth_printer_service.dart';
import '../services/api_service.dart';
import '../services/offline_sync_service.dart';
import '../utils/payment_utils.dart';
import '../widgets/invoice/customer_selection_dialog.dart';
import '../widgets/product_image_thumbnail.dart';
import '../widgets/product_image_download_button.dart';

class QuotationPage extends StatefulWidget {
  const QuotationPage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  State<QuotationPage> createState() => _QuotationPageState();
}

class _DiscountValidationResult {
  const _DiscountValidationResult({
    this.errorMessage,
    this.itemLabel,
    this.quantity,
    this.freeQuantity,
    this.discountLabel,
    this.finalPrice,
    this.summary,
  });

  final String? errorMessage;
  final String? itemLabel;
  final int? quantity;
  final int? freeQuantity;
  final String? discountLabel;
  final double? finalPrice;
  final String? summary;
}

class _QuotationPageState extends State<QuotationPage>
    with WidgetsBindingObserver {
  static const String _activeDraftKey = 'quotation_active_draft';

  String _salesType = 'Retail';
  final _manualController = TextEditingController();
  final _remarksController = TextEditingController();
  final _poNumberController = TextEditingController();
  final List<Map<String, dynamic>> _rows = [];
  Map<String, String>? _selectedQuotation;
  Map<String, String>? _selectedSalesOrder;
  Map<String, String>? _selectedCustomer;

  double _salesOrderDiscount = 0.0;
  bool _isPercentageDiscount = true;
  String? _selectedTax;

  // Date selection
  DateTime? _selectedDate = DateTime.now(); // Default to current date

  // Track if current customer has saved data
  bool _hasSavedDataForCustomer = false;
  bool _isSyncingOfflineSalesOrders = false;
  int _pendingSalesOrderCount = 0;
  Timer? _draftPersistTimer;
  bool _suppressDraftPersist = false;

  bool get _isQuotationMode => true;
  String get _documentTitle => _isQuotationMode ? 'Quotation' : 'Sales Order';
  String get _documentTitleLower =>
      _isQuotationMode ? 'quotation' : 'sales order';
  String get _postDialogTitle =>
      _isQuotationMode ? 'Post Quotation' : 'Post Sales Order';
  String get _postButtonLabel =>
      _isQuotationMode ? 'Post Quotation' : 'Post Sales Order';
  String get _itemsTitle =>
      _isQuotationMode ? 'Quotation Items' : 'Sales Order Items';
  String get _summaryTitle =>
      _isQuotationMode ? 'Quotation Summary' : 'Sales Order Summary';
  Color get _accentColor =>
      _isQuotationMode ? const Color(0xFF2F2B6E) : const Color(0xFF2F2B6E);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize with current date as default
    _selectedDate = DateTime.now();
    _poNumberController.addListener(_scheduleDraftPersistFromController);
    _manualController.addListener(_scheduleDraftPersistFromController);
    // Check if current customer has saved data when page loads
    _checkForSavedData();
    _loadPendingSalesOrderCount();
    _restoreActiveDraft();
  }

  void _scheduleDraftPersistFromController() {
    _persistActiveDraft();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _persistActiveDraft(immediate: true);
    }
  }

  Future<void> _loadPendingSalesOrderCount() async {
    final count = await OfflineSyncService.getPendingSalesOrderCount();
    if (!mounted) return;
    setState(() => _pendingSalesOrderCount = count);
  }

  Future<void> _syncPendingSalesOrders() async {
    setState(() => _isSyncingOfflineSalesOrders = true);

    try {
      final result = await OfflineSyncService.syncPendingSalesOrders();
      await _loadPendingSalesOrderCount();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message ??
                'Sales order sync: ${result.synced} synced, ${result.failed} failed, ${result.remaining} pending.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSyncingOfflineSalesOrders = false);
    }
  }

  // Temporary save/recall functionality
  Future<SharedPreferences?> _getSharedPreferences() async {
    try {
      // Ensure WidgetsFlutterBinding is initialized
      WidgetsFlutterBinding.ensureInitialized();
      return await SharedPreferences.getInstance();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'SharedPreferences not available. Please stop the app completely and rebuild it.\nError: $e',
            ),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 6),
          ),
        );
      }
      return null;
    }
  }

  Map<String, dynamic> _deepCopyMap(Map<String, dynamic> source) {
    final Map<String, dynamic> copy = {};
    source.forEach((key, value) {
      if (value is Map) {
        copy[key] = Map<String, dynamic>.from(value);
      } else if (value is List) {
        copy[key] = List.from(value);
      } else {
        copy[key] = value;
      }
    });
    return copy;
  }

  Map<String, dynamic>? _buildActiveDraftData() {
    if (_rows.isEmpty && _selectedCustomer == null) return null;

    return {
      'customer': _selectedCustomer != null
          ? Map<String, String>.from(_selectedCustomer!)
          : null,
      'rows': _rows.map(_deepCopyMap).toList(),
      'discount': _salesOrderDiscount,
      'isPercentageDiscount': _isPercentageDiscount,
      'tax': _selectedTax,
      'salesType': _salesType,
      'remarks': _remarksController.text,
      'manual': _manualController.text,
      'poNumber': _poNumberController.text,
      'date': (_selectedDate ?? DateTime.now()).toIso8601String(),
      'selectedQuotation': _selectedQuotation,
      'selectedSalesOrder': _selectedSalesOrder,
    };
  }

  Future<void> _persistActiveDraft({bool immediate = false}) async {
    if (_suppressDraftPersist) return;

    Future<void> writeDraft() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final draft = _buildActiveDraftData();
        if (draft == null || _rows.isEmpty) {
          await prefs.remove(_activeDraftKey);
          return;
        }
        await prefs.setString(_activeDraftKey, jsonEncode(draft));
      } catch (_) {
        // Best-effort persistence; ignore write failures.
      }
    }

    _draftPersistTimer?.cancel();
    if (immediate) {
      await writeDraft();
    } else {
      _draftPersistTimer = Timer(
        const Duration(milliseconds: 300),
        writeDraft,
      );
    }
  }

  Future<void> _clearActiveDraft() async {
    _draftPersistTimer?.cancel();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_activeDraftKey);
    } catch (_) {
      // Ignore clear failures.
    }
  }

  Future<void> _restoreActiveDraft() async {
    try {
      final prefs = await _getSharedPreferences();
      if (prefs == null) return;

      final savedData = prefs.getString(_activeDraftKey);
      if (savedData == null || savedData.isEmpty) return;

      final data = jsonDecode(savedData) as Map<String, dynamic>;
      final savedRows = data['rows'];
      if (savedRows is! List || savedRows.isEmpty) return;

      _suppressDraftPersist = true;
      if (!mounted) return;

      setState(() {
        if (data['customer'] is Map) {
          _selectedCustomer = (data['customer'] as Map).map(
            (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
          );
        }
        _rows
          ..clear()
          ..addAll(
            savedRows.map(
              (e) => Map<String, dynamic>.from(e as Map),
            ),
          );
        _salesOrderDiscount = (data['discount'] as num?)?.toDouble() ?? 0.0;
        _isPercentageDiscount = data['isPercentageDiscount'] as bool? ?? true;
        _selectedTax = data['tax'] as String?;
        _salesType = data['salesType'] as String? ?? 'Retail';
        _remarksController.text = data['remarks'] as String? ?? '';
        _manualController.text = data['manual'] as String? ?? '';
        _poNumberController.text = data['poNumber'] as String? ?? '';
        final savedDate = data['date'] as String?;
        if (savedDate != null && savedDate.isNotEmpty) {
          _selectedDate = DateTime.tryParse(savedDate) ?? DateTime.now();
        }
        if (data['selectedQuotation'] is Map) {
          _selectedQuotation = (data['selectedQuotation'] as Map).map(
            (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
          );
        }
        if (data['selectedSalesOrder'] is Map) {
          _selectedSalesOrder = (data['selectedSalesOrder'] as Map).map(
            (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
          );
        }
      });

      if (!mounted) return;
      final cart = Provider.of<CartProvider>(context, listen: false);
      cart.setCustomerInfo(name: _selectedCustomer?['name']);
      await _checkForSavedData();
    } catch (_) {
      // Ignore corrupt drafts and keep a clean form.
    } finally {
      _suppressDraftPersist = false;
    }
  }

  Future<void> _saveTemporaryData() async {
    if (_selectedCustomer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please select a customer first'),
          backgroundColor: _accentColor,
        ),
      );
      return;
    }

    if (_rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No items to save'),
          backgroundColor: _accentColor,
        ),
      );
      return;
    }

    try {
      final prefs = await _getSharedPreferences();
      if (prefs == null) return;
      final customerId = _selectedCustomer!['id'] ?? _selectedCustomer!['name'];
      final key = 'quotation_temp_$customerId';

      // Create a deep copy of rows to avoid modifying the original
      final rowsCopy = _rows.map(_deepCopyMap).toList();

      // Create a copy of customer data
      final customerCopy = Map<String, String>.from(_selectedCustomer!);

      final dataToSave = {
        'customer': customerCopy,
        'rows': rowsCopy,
        'discount': _salesOrderDiscount,
        'isPercentageDiscount': _isPercentageDiscount,
        'tax': _selectedTax,
        'salesType': _salesType,
        'remarks': _remarksController.text,
        'manual': _manualController.text,
        'date': DateTime.now().toIso8601String(),
      };

      // Encode to JSON first to catch any serialization errors
      String jsonString;
      try {
        jsonString = jsonEncode(dataToSave);
      } catch (encodeError) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error encoding data: $encodeError'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return; // Exit early, don't modify any state
      }

      await prefs.setString(key, jsonString);
      await _clearActiveDraft();

      if (mounted) {
        // Clear the UI after successful save
        final cart = Provider.of<CartProvider>(context, listen: false);
        setState(() {
          // Clear customer selection
          _selectedCustomer = null;
          _selectedQuotation = null;
          _selectedSalesOrder = null;
          // Clear table rows
          _rows.clear();
          // Clear discount and tax
          _salesOrderDiscount = 0.0;
          _selectedTax = null;
          // Clear text fields
          _remarksController.clear();
          _manualController.clear();
          _poNumberController.clear();
          // Reset saved data flag since customer is cleared
          _hasSavedDataForCustomer = false;
        });
        // Clear cart provider customer info
        cart.setCustomerInfo(name: null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Temporarily saved successfully'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      // Don't modify any state on error - keep customer and rows intact
      if (mounted) {
        final errorMessage = e.toString().contains('MissingPluginException')
            ? 'Plugin not initialized. Please restart the app completely (stop and rebuild).'
            : 'Error saving: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<bool> _hasSavedData() async {
    if (_selectedCustomer == null) return false;
    try {
      final prefs = await _getSharedPreferences();
      if (prefs == null) return false;
      final customerId = _selectedCustomer!['id'] ?? _selectedCustomer!['name'];
      final key = 'quotation_temp_$customerId';
      return prefs.containsKey(key);
    } catch (e) {
      return false;
    }
  }

  Future<void> _recallTemporaryData() async {
    if (_selectedCustomer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please select a customer first'),
          backgroundColor: _accentColor,
        ),
      );
      return;
    }

    try {
      final prefs = await _getSharedPreferences();
      if (prefs == null) return;
      final customerId = _selectedCustomer!['id'] ?? _selectedCustomer!['name'];
      final key = 'quotation_temp_$customerId';

      final savedData = prefs.getString(key);
      if (savedData == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('No saved data found for this customer'),
            backgroundColor: _accentColor,
          ),
        );
        return;
      }

      final data = jsonDecode(savedData) as Map<String, dynamic>;

      setState(() {
        _rows.clear();
        if (data['rows'] != null) {
          _rows.addAll(
            (data['rows'] as List).map((e) => e as Map<String, dynamic>),
          );
        }
        _salesOrderDiscount = (data['discount'] as num?)?.toDouble() ?? 0.0;
        _isPercentageDiscount = data['isPercentageDiscount'] as bool? ?? true;
        _selectedTax = data['tax'] as String?;
        _salesType = data['salesType'] as String? ?? 'Retail';
        _remarksController.text = data['remarks'] as String? ?? '';
        _manualController.text = data['manual'] as String? ?? '';
        _selectedDate = DateTime.now();
      });

      if (mounted) {
        // Refresh saved data state after recall
        _checkForSavedData();
        _persistActiveDraft();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Data recalled successfully'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final errorMessage = e.toString().contains('MissingPluginException')
            ? 'Plugin not initialized. Please restart the app completely (stop and rebuild).'
            : 'Error recalling data: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _checkForSavedData() async {
    // Check if customer has saved data when customer is selected
    if (_selectedCustomer != null) {
      final hasData = await _hasSavedData();
      if (mounted) {
        setState(() {
          _hasSavedDataForCustomer = hasData;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _hasSavedDataForCustomer = false;
        });
      }
    }
  }

  // Customers fetched from database
  List<Map<String, dynamic>> _customers = [];
  bool _isLoadingCustomers = false;

  // Products fetched from database
  List<Map<String, dynamic>> _products = [];
  bool _isLoadingProducts = false;

  static const List<Map<String, String>> _mockQuotations = [
    {
      'id': 'QT-1001',
      'customer': 'Sun Plastics',
      'date': '12 Aug 2024',
      'amount': 'Rs. 32,500.00',
    },
    {
      'id': 'QT-1005',
      'customer': 'Green Polywares',
      'date': '03 Sep 2024',
      'amount': 'Rs. 18,200.00',
    },
    {
      'id': 'QT-1010',
      'customer': 'Sun Plastics',
      'date': '21 Sep 2024',
      'amount': 'Rs. 44,950.00',
    },
  ];

  static const List<Map<String, String>> _mockSalesOrders = [
    {
      'id': 'SO-2308',
      'customer': 'Green Polywares',
      'date': '08 Oct 2024',
      'amount': 'Rs. 56,780.00',
    },
    {
      'id': 'SO-2312',
      'customer': 'Sun Plastics',
      'date': '11 Oct 2024',
      'amount': 'Rs. 24,990.00',
    },
    {
      'id': 'SO-2320',
      'customer': 'Green Polywares',
      'date': '18 Oct 2024',
      'amount': 'Rs. 87,400.00',
    },
  ];

  List<Map<String, String>> get _filteredQuotations => _selectedCustomer != null
      ? _mockQuotations
            .where((q) => q['customer'] == _selectedCustomer!['name'])
            .toList()
      : [];

  List<Map<String, String>> get _filteredSalesOrders =>
      _selectedCustomer != null
      ? _mockSalesOrders
            .where((so) => so['customer'] == _selectedCustomer!['name'])
            .toList()
      : [];

  // Helper function to get the correct price based on sales type
  double _getPriceForItem(Map<String, dynamic> item) {
    if (_salesType == 'Retail') {
      return (item['unitPrice'] as num?)?.toDouble() ?? 0.0;
    } else {
      // WholeSale
      return (item['wholeSalePrice'] as num?)?.toDouble() ?? 0.0;
    }
  }

  // Helper function to get price from row (for backward compatibility)
  double _getPriceFromRow(Map<String, dynamic> row) {
    // If row has both prices stored, use based on sales type
    if (row.containsKey('unitPrice') && row.containsKey('wholeSalePrice')) {
      return _salesType == 'Retail'
          ? (row['unitPrice'] as num?)?.toDouble() ?? 0.0
          : (row['wholeSalePrice'] as num?)?.toDouble() ?? 0.0;
    }
    // Fallback to 'price' field
    return (row['price'] as num?)?.toDouble() ?? 0.0;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draftPersistTimer?.cancel();
    _poNumberController.removeListener(_scheduleDraftPersistFromController);
    _manualController.removeListener(_scheduleDraftPersistFromController);
    // Capture draft before disposing controllers; write asynchronously.
    final draft = _buildActiveDraftData();
    final encoded = (draft != null && _rows.isNotEmpty)
        ? jsonEncode(draft)
        : null;
    SharedPreferences.getInstance().then((prefs) {
      if (encoded == null) {
        prefs.remove(_activeDraftKey);
      } else {
        prefs.setString(_activeDraftKey, encoded);
      }
    });
    _manualController.dispose();
    _remarksController.dispose();
    _poNumberController.dispose();
    super.dispose();
  }

  _DiscountValidationResult _validateDiscount({
    required Map<String, dynamic>? selectedItem,
    required String quantityText,
    required String freeQuantityText,
    required String discountText,
    required bool useAmountDiscount,
  }) {
    if (selectedItem == null) {
      return const _DiscountValidationResult(
        errorMessage: 'Select an item first.',
      );
    }

    final quantity = int.tryParse(quantityText.trim());
    if (quantity == null || quantity <= 0) {
      return const _DiscountValidationResult(
        errorMessage: 'Quantity must be above zero.',
      );
    }

    final freeQuantity = int.tryParse(
      freeQuantityText.trim().isEmpty ? '0' : freeQuantityText.trim(),
    );
    if (freeQuantity == null || freeQuantity < 0) {
      return const _DiscountValidationResult(
        errorMessage: 'Enter a valid free quantity.',
      );
    }

    final discountValue = double.tryParse(
      discountText.trim().isEmpty ? '0' : discountText.trim(),
    );
    if (discountValue == null || discountValue < 0) {
      return const _DiscountValidationResult(
        errorMessage: 'Enter a valid discount.',
      );
    }

    final unitPrice = _getPriceForItem(selectedItem);
    final totalPrice = unitPrice * quantity;
    double discountAmount;

    if (!useAmountDiscount) {
      if (discountValue > 100) {
        return const _DiscountValidationResult(
          errorMessage: 'Discount % cannot exceed 100.',
        );
      }
      discountAmount = totalPrice * (discountValue / 100);
    } else {
      if (discountValue > totalPrice) {
        return const _DiscountValidationResult(
          errorMessage: 'Discount exceeds total.',
        );
      }
      discountAmount = discountValue;
    }

    double finalPrice = totalPrice - discountAmount;
    if (finalPrice < 0) {
      finalPrice = 0;
    }
    finalPrice = double.parse(finalPrice.toStringAsFixed(2));

    final discountLabel = useAmountDiscount
        ? 'Rs ${discountAmount.toStringAsFixed(2)}'
        : '${discountValue.toStringAsFixed(2)}%';

    final summary =
        '${useAmountDiscount ? 'Flat' : 'Percent'} discount • Net Rs ${finalPrice.toStringAsFixed(2)}';

    return _DiscountValidationResult(
      itemLabel: '${selectedItem['code']} • ${selectedItem['name']}',
      quantity: quantity,
      freeQuantity: freeQuantity,
      discountLabel: discountLabel,
      finalPrice: finalPrice,
      summary: summary,
    );
  }

  Future<Map<String, String>?> _showCustomerDialog() async {
    if (_customers.isEmpty) {
      setState(() {
        _isLoadingCustomers = true;
      });
      try {
        final result = await OfflineSyncService.getCustomersForSelection(
          salesRepCode: '', // Show all customers for quotation
        );
        if (mounted) {
          setState(() {
            _customers = result;
            _isLoadingCustomers = false;
          });
        }
      } catch (e) {
        if (mounted) {
          final offlineCustomers =
              await OfflineSyncService.getPendingCustomersForSelection(
                salesRepCode: '', // Show all offline customers for quotation
              );
          setState(() {
            _customers = offlineCustomers;
            _isLoadingCustomers = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                offlineCustomers.isEmpty
                    ? 'Failed to load customers.'
                    : 'Offline area. Showing locally saved customers.',
              ),
              backgroundColor: offlineCustomers.isEmpty
                  ? Colors.red
                  : _accentColor,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    }

    // Convert customers to Map<String, String> format for the dialog
    final customersForDialog = _customers.map((customer) {
      final code = customer['code']?.toString() ?? '';
      final name = customer['name']?.toString() ?? '';
      final phone = customer['phone']?.toString() ?? '';
      final contactPerson = customer['contactPerson']?.toString() ?? '';
      final address = customer['address']?.toString() ??
          [
            customer['address1']?.toString() ?? '',
            customer['address2']?.toString() ?? '',
            customer['address3']?.toString() ?? '',
          ].where((p) => p.trim().isNotEmpty).join(', ');
      final creditPeriod =
          customer['creditPeriod']?.toString() ??
          customer['CreditPeriod']?.toString() ??
          '0';

      return <String, String>{
        'code': code,
        'name': name,
        'phone': phone,
        'contactPerson': contactPerson,
        'address': address,
        'creditPeriod': creditPeriod,
      };
    }).toList();

    print('📦 Showing dialog with ${customersForDialog.length} customers');
    if (customersForDialog.isNotEmpty) {
      print('📋 First customer in dialog: ${customersForDialog.first}');
    }

    return showDialog<Map<String, String>?>(
      context: context,
      builder: (dialogContext) => CustomerSelectionDialog(
        customers: customersForDialog,
        isLoading: _isLoadingCustomers,
      ),
    );
  }

  // Show payment details popup based on payment method
  Future<Map<String, dynamic>?> _showPaymentDetailsPopup(
    BuildContext context,
    String paymentMethodId,
    Map<String, dynamic> paymentMethod,
    double totalAmount,
    Map<String, dynamic>? existingDetails,
    List<Map<String, dynamic>> allPaymentMethods,
  ) async {
    final theme = Theme.of(context);
    Map<String, dynamic> result = {};

    switch (paymentMethodId) {
      case 'cash':
        // Cash: Amount only (with remaining amount display)
        final amountController = TextEditingController(
          text:
              existingDetails?['Amount']?.toString() ??
              totalAmount.toStringAsFixed(2),
        );
        result =
            await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (dialogContext) {
                return StatefulBuilder(
                  builder: (dialogContext, setDialogState) {
                    final enteredAmount =
                        double.tryParse(amountController.text) ?? 0.0;
                    final remainingAmount = (totalAmount - enteredAmount).clamp(
                      0,
                      double.infinity,
                    );
                    final hasRemaining = remainingAmount > 0.01;
                    // User must explicitly select the remaining payment method - no default
                    String? selectedRemainingPaymentMethod =
                        existingDetails?['RemainingPaymentMethod']?.toString();
                    // Store remaining payment method details
                    Map<String, dynamic> remainingPaymentDetails =
                        existingDetails?['RemainingPaymentDetails'] ?? {};

                    return AlertDialog(
                      title: Row(
                        children: [
                          Icon(
                            Icons.money_rounded,
                            color: const Color(0xFF2F2B6E),
                          ),
                          const SizedBox(width: 12),
                          const Text('Cash Payment'),
                        ],
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: amountController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.]'),
                              ),
                            ],
                            decoration: InputDecoration(
                              labelText: 'Amount',
                              prefixText: 'Rs. ',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              suffixText:
                                  'of Rs. ${totalAmount.toStringAsFixed(2)}',
                            ),
                            onChanged: (value) {
                              setDialogState(() {});
                            },
                          ),
                          if (hasRemaining) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Remaining Amount: Rs. ${remainingAmount.toStringAsFixed(2)}',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              value: selectedRemainingPaymentMethod,
                              decoration: InputDecoration(
                                labelText:
                                    'Select Payment Method for Remaining *',
                                hintText: 'Choose Payment',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                filled: true,
                                fillColor: Colors.white,
                                prefixIcon: const Icon(Icons.payment_rounded),
                              ),
                              items: allPaymentMethods.map((method) {
                                return DropdownMenuItem<String>(
                                  value: method['id'],
                                  child: Row(
                                    children: [
                                      Icon(
                                        _getPaymentIcon(method['id']),
                                        size: 20,
                                        color: const Color(0xFF2F2B6E),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(method['name']),
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: (value) async {
                                if (value != null) {
                                  setDialogState(() {
                                    selectedRemainingPaymentMethod = value;
                                    // Clear remaining payment details when method changes
                                    remainingPaymentDetails = {};
                                  });
                                  // Automatically open payment details popup for remaining payment method
                                  final remainingMethod = allPaymentMethods
                                      .firstWhere(
                                        (m) => m['id'] == value,
                                        orElse: () => allPaymentMethods.first,
                                      );
                                  final details =
                                      await _showPaymentDetailsPopup(
                                        dialogContext,
                                        value,
                                        remainingMethod,
                                        remainingAmount.toDouble(),
                                        remainingPaymentDetails,
                                        allPaymentMethods,
                                      );
                                  if (details != null &&
                                      details.containsKey('Amount')) {
                                    setDialogState(() {
                                      // Store only the payment details, not the amount (amount is fixed as remaining)
                                      remainingPaymentDetails = Map.from(
                                        details,
                                      );
                                      remainingPaymentDetails.remove('Amount');
                                      remainingPaymentDetails.remove(
                                        'RemainingAmount',
                                      );
                                      remainingPaymentDetails.remove(
                                        'RemainingPaymentMethod',
                                      );
                                    });
                                  }
                                }
                              },
                            ),
                            // Show payment details input for remaining payment method
                            if (selectedRemainingPaymentMethod != null) ...[
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: () async {
                                  final remainingMethod = allPaymentMethods
                                      .firstWhere(
                                        (m) =>
                                            m['id'] ==
                                            selectedRemainingPaymentMethod,
                                        orElse: () => allPaymentMethods.first,
                                      );
                                  final details =
                                      await _showPaymentDetailsPopup(
                                        dialogContext,
                                        selectedRemainingPaymentMethod!,
                                        remainingMethod,
                                        remainingAmount.toDouble(),
                                        remainingPaymentDetails,
                                        allPaymentMethods,
                                      );
                                  if (details != null &&
                                      details.containsKey('Amount')) {
                                    setDialogState(() {
                                      // Store only the payment details, not the amount (amount is fixed as remaining)
                                      remainingPaymentDetails = Map.from(
                                        details,
                                      );
                                      remainingPaymentDetails.remove('Amount');
                                      remainingPaymentDetails.remove(
                                        'RemainingAmount',
                                      );
                                      remainingPaymentDetails.remove(
                                        'RemainingPaymentMethod',
                                      );
                                    });
                                  }
                                },
                                icon: const Icon(Icons.edit_rounded),
                                label: Text(
                                  remainingPaymentDetails.isNotEmpty
                                      ? 'Edit Remaining Payment Details'
                                      : 'Enter Remaining Payment Details',
                                ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(
                                    0xFF2F2B6E,
                                  ).withOpacity(0.1),
                                  foregroundColor: const Color(0xFF2F2B6E),
                                ),
                              ),
                              if (remainingPaymentDetails.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: theme
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: theme.colorScheme.outline
                                          .withOpacity(0.2),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Remaining Payment Details:',
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      const SizedBox(height: 8),
                                      ...remainingPaymentDetails.entries.map((
                                        entry,
                                      ) {
                                        if (entry.value == null ||
                                            entry.value.toString().isEmpty) {
                                          return const SizedBox.shrink();
                                        }
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 4,
                                          ),
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${entry.key}: ',
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                              Expanded(
                                                child: Text(
                                                  entry.value.toString(),
                                                  style:
                                                      theme.textTheme.bodySmall,
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      }).toList(),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(null),
                          child: const Text('Cancel'),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF2F2B6E),
                          ),
                        ),
                        FilledButton(
                          onPressed: () {
                            final amount = double.tryParse(
                              amountController.text,
                            );
                            if (amount == null || amount <= 0) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text('Please enter a valid amount'),
                                ),
                              );
                              return;
                            }
                            if (amount > totalAmount) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Amount cannot exceed total: Rs. ${totalAmount.toStringAsFixed(2)}',
                                  ),
                                ),
                              );
                              return;
                            }
                            if (hasRemaining &&
                                selectedRemainingPaymentMethod == null) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Please select a payment method for the remaining amount',
                                  ),
                                ),
                              );
                              return;
                            }
                            final remainingPaymentMethod = hasRemaining
                                ? selectedRemainingPaymentMethod
                                : null;
                            Navigator.of(dialogContext).pop({
                              'Amount': amount,
                              'RemainingAmount': remainingAmount,
                              'RemainingPaymentMethod': remainingPaymentMethod,
                              'RemainingPaymentDetails':
                                  remainingPaymentDetails,
                            });
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF2F2B6E),
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Confirm'),
                        ),
                      ],
                    );
                  },
                );
              },
            ) ??
            {};
        break;

      case 'master_card':
      case 'visa_card':
      case 'amex_card':
        // Card: Card Number + Amount (with remaining amount display)
        final cardNumberController = TextEditingController(
          text: existingDetails?['Card Number']?.toString() ?? '',
        );
        final amountController = TextEditingController(
          text:
              existingDetails?['Amount']?.toString() ??
              totalAmount.toStringAsFixed(2),
        );
        final cardName = paymentMethod['name'];
        result =
            await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (dialogContext) {
                return StatefulBuilder(
                  builder: (dialogContext, setDialogState) {
                    final enteredAmount =
                        double.tryParse(amountController.text) ?? 0.0;
                    final remainingAmount = (totalAmount - enteredAmount).clamp(
                      0,
                      double.infinity,
                    );
                    final hasRemaining = remainingAmount > 0.01;
                    // User must explicitly select the remaining payment method - no default
                    String? selectedRemainingPaymentMethod =
                        existingDetails?['RemainingPaymentMethod']?.toString();
                    // Store remaining payment method details
                    Map<String, dynamic> remainingPaymentDetails =
                        existingDetails?['RemainingPaymentDetails'] ?? {};

                    return AlertDialog(
                      title: Row(
                        children: [
                          Icon(
                            Icons.credit_card_rounded,
                            color: const Color(0xFF2F2B6E),
                          ),
                          const SizedBox(width: 12),
                          Text('$cardName Payment'),
                        ],
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: cardNumberController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: InputDecoration(
                              labelText: '$cardName Number',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              prefixIcon: const Icon(Icons.credit_card_rounded),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: amountController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.]'),
                              ),
                            ],
                            decoration: InputDecoration(
                              labelText: 'Amount',
                              prefixText: 'Rs. ',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              suffixText:
                                  'of Rs. ${totalAmount.toStringAsFixed(2)}',
                            ),
                            onChanged: (value) {
                              setDialogState(() {});
                            },
                          ),
                          if (hasRemaining) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Remaining Amount: Rs. ${remainingAmount.toStringAsFixed(2)}',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              value: selectedRemainingPaymentMethod,
                              decoration: InputDecoration(
                                labelText:
                                    'Select Payment Method for Remaining *',
                                hintText: 'Choose Payment',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                filled: true,
                                fillColor: Colors.white,
                                prefixIcon: const Icon(Icons.payment_rounded),
                              ),
                              items: allPaymentMethods.map((method) {
                                return DropdownMenuItem<String>(
                                  value: method['id'],
                                  child: Row(
                                    children: [
                                      Icon(
                                        _getPaymentIcon(method['id']),
                                        size: 20,
                                        color: const Color(0xFF2F2B6E),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(method['name']),
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: (value) async {
                                if (value != null) {
                                  setDialogState(() {
                                    selectedRemainingPaymentMethod = value;
                                    // Clear remaining payment details when method changes
                                    remainingPaymentDetails = {};
                                  });
                                  // Automatically open payment details popup for remaining payment method
                                  final remainingMethod = allPaymentMethods
                                      .firstWhere(
                                        (m) => m['id'] == value,
                                        orElse: () => allPaymentMethods.first,
                                      );
                                  final details =
                                      await _showPaymentDetailsPopup(
                                        dialogContext,
                                        value,
                                        remainingMethod,
                                        remainingAmount.toDouble(),
                                        remainingPaymentDetails,
                                        allPaymentMethods,
                                      );
                                  if (details != null &&
                                      details.containsKey('Amount')) {
                                    setDialogState(() {
                                      // Store only the payment details, not the amount (amount is fixed as remaining)
                                      remainingPaymentDetails = Map.from(
                                        details,
                                      );
                                      remainingPaymentDetails.remove('Amount');
                                      remainingPaymentDetails.remove(
                                        'RemainingAmount',
                                      );
                                      remainingPaymentDetails.remove(
                                        'RemainingPaymentMethod',
                                      );
                                    });
                                  }
                                }
                              },
                            ),
                            // Show payment details input for remaining payment method
                            if (selectedRemainingPaymentMethod != null) ...[
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: () async {
                                  final remainingMethod = allPaymentMethods
                                      .firstWhere(
                                        (m) =>
                                            m['id'] ==
                                            selectedRemainingPaymentMethod,
                                        orElse: () => allPaymentMethods.first,
                                      );
                                  final details =
                                      await _showPaymentDetailsPopup(
                                        dialogContext,
                                        selectedRemainingPaymentMethod!,
                                        remainingMethod,
                                        remainingAmount.toDouble(),
                                        remainingPaymentDetails,
                                        allPaymentMethods,
                                      );
                                  if (details != null &&
                                      details.containsKey('Amount')) {
                                    setDialogState(() {
                                      // Store only the payment details, not the amount (amount is fixed as remaining)
                                      remainingPaymentDetails = Map.from(
                                        details,
                                      );
                                      remainingPaymentDetails.remove('Amount');
                                      remainingPaymentDetails.remove(
                                        'RemainingAmount',
                                      );
                                      remainingPaymentDetails.remove(
                                        'RemainingPaymentMethod',
                                      );
                                    });
                                  }
                                },
                                icon: const Icon(Icons.edit_rounded),
                                label: Text(
                                  remainingPaymentDetails.isNotEmpty
                                      ? 'Edit Remaining Payment Details'
                                      : 'Enter Remaining Payment Details',
                                ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(
                                    0xFF2F2B6E,
                                  ).withOpacity(0.1),
                                  foregroundColor: const Color(0xFF2F2B6E),
                                ),
                              ),
                              if (remainingPaymentDetails.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: theme
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: theme.colorScheme.outline
                                          .withOpacity(0.2),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Remaining Payment Details:',
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      const SizedBox(height: 8),
                                      ...remainingPaymentDetails.entries.map((
                                        entry,
                                      ) {
                                        if (entry.value == null ||
                                            entry.value.toString().isEmpty) {
                                          return const SizedBox.shrink();
                                        }
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 4,
                                          ),
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${entry.key}: ',
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                              Expanded(
                                                child: Text(
                                                  entry.value.toString(),
                                                  style:
                                                      theme.textTheme.bodySmall,
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      }).toList(),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(null),
                          child: const Text('Cancel'),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF2F2B6E),
                          ),
                        ),
                        FilledButton(
                          onPressed: () {
                            if (cardNumberController.text.trim().isEmpty) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Please enter $cardName number',
                                  ),
                                ),
                              );
                              return;
                            }
                            final amount = double.tryParse(
                              amountController.text,
                            );
                            if (amount == null || amount <= 0) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text('Please enter a valid amount'),
                                ),
                              );
                              return;
                            }
                            if (amount > totalAmount) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Amount cannot exceed total: Rs. ${totalAmount.toStringAsFixed(2)}',
                                  ),
                                ),
                              );
                              return;
                            }
                            final remainingPaymentMethod = hasRemaining
                                ? selectedRemainingPaymentMethod
                                : null;
                            Navigator.of(dialogContext).pop({
                              'Card Number': cardNumberController.text.trim(),
                              'Amount': amount,
                              'RemainingAmount': remainingAmount,
                              'RemainingPaymentMethod': remainingPaymentMethod,
                            });
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF2F2B6E),
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Confirm'),
                        ),
                      ],
                    );
                  },
                );
              },
            ) ??
            {};
        break;

      case 'credit':
        // Credit: Amount only (with remaining amount display)
        final amountController = TextEditingController(
          text:
              existingDetails?['Amount']?.toString() ??
              totalAmount.toStringAsFixed(2),
        );
        result =
            await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (dialogContext) {
                return StatefulBuilder(
                  builder: (dialogContext, setDialogState) {
                    final enteredAmount =
                        double.tryParse(amountController.text) ?? 0.0;
                    final remainingAmount = (totalAmount - enteredAmount).clamp(
                      0,
                      double.infinity,
                    );
                    final hasRemaining = remainingAmount > 0.01;
                    // User must explicitly select the remaining payment method - no default
                    String? selectedRemainingPaymentMethod =
                        existingDetails?['RemainingPaymentMethod']?.toString();
                    // Store remaining payment method details
                    Map<String, dynamic> remainingPaymentDetails =
                        existingDetails?['RemainingPaymentDetails'] ?? {};

                    return AlertDialog(
                      title: Row(
                        children: [
                          Icon(
                            Icons.account_balance_rounded,
                            color: const Color(0xFF2F2B6E),
                          ),
                          const SizedBox(width: 12),
                          const Text('Credit Payment'),
                        ],
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: amountController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.]'),
                              ),
                            ],
                            decoration: InputDecoration(
                              labelText: 'Amount',
                              prefixText: 'Rs. ',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              suffixText:
                                  'of Rs. ${totalAmount.toStringAsFixed(2)}',
                            ),
                            onChanged: (value) {
                              setDialogState(() {});
                            },
                          ),
                          if (hasRemaining) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Remaining Amount: Rs. ${remainingAmount.toStringAsFixed(2)}',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              value: selectedRemainingPaymentMethod,
                              decoration: InputDecoration(
                                labelText:
                                    'Select Payment Method for Remaining *',
                                hintText: 'Choose Payment',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                filled: true,
                                fillColor: Colors.white,
                                prefixIcon: const Icon(Icons.payment_rounded),
                              ),
                              items: allPaymentMethods.map((method) {
                                return DropdownMenuItem<String>(
                                  value: method['id'],
                                  child: Row(
                                    children: [
                                      Icon(
                                        _getPaymentIcon(method['id']),
                                        size: 20,
                                        color: const Color(0xFF2F2B6E),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(method['name']),
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: (value) async {
                                if (value != null) {
                                  setDialogState(() {
                                    selectedRemainingPaymentMethod = value;
                                    // Clear remaining payment details when method changes
                                    remainingPaymentDetails = {};
                                  });
                                  // Automatically open payment details popup for remaining payment method
                                  final remainingMethod = allPaymentMethods
                                      .firstWhere(
                                        (m) => m['id'] == value,
                                        orElse: () => allPaymentMethods.first,
                                      );
                                  final details =
                                      await _showPaymentDetailsPopup(
                                        dialogContext,
                                        value,
                                        remainingMethod,
                                        remainingAmount.toDouble(),
                                        remainingPaymentDetails,
                                        allPaymentMethods,
                                      );
                                  if (details != null &&
                                      details.containsKey('Amount')) {
                                    setDialogState(() {
                                      // Store only the payment details, not the amount (amount is fixed as remaining)
                                      remainingPaymentDetails = Map.from(
                                        details,
                                      );
                                      remainingPaymentDetails.remove('Amount');
                                      remainingPaymentDetails.remove(
                                        'RemainingAmount',
                                      );
                                      remainingPaymentDetails.remove(
                                        'RemainingPaymentMethod',
                                      );
                                    });
                                  }
                                }
                              },
                            ),
                            // Show payment details input for remaining payment method
                            if (selectedRemainingPaymentMethod != null) ...[
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: () async {
                                  final remainingMethod = allPaymentMethods
                                      .firstWhere(
                                        (m) =>
                                            m['id'] ==
                                            selectedRemainingPaymentMethod,
                                        orElse: () => allPaymentMethods.first,
                                      );
                                  final details =
                                      await _showPaymentDetailsPopup(
                                        dialogContext,
                                        selectedRemainingPaymentMethod!,
                                        remainingMethod,
                                        remainingAmount.toDouble(),
                                        remainingPaymentDetails,
                                        allPaymentMethods,
                                      );
                                  if (details != null &&
                                      details.containsKey('Amount')) {
                                    setDialogState(() {
                                      // Store only the payment details, not the amount (amount is fixed as remaining)
                                      remainingPaymentDetails = Map.from(
                                        details,
                                      );
                                      remainingPaymentDetails.remove('Amount');
                                      remainingPaymentDetails.remove(
                                        'RemainingAmount',
                                      );
                                      remainingPaymentDetails.remove(
                                        'RemainingPaymentMethod',
                                      );
                                    });
                                  }
                                },
                                icon: const Icon(Icons.edit_rounded),
                                label: Text(
                                  remainingPaymentDetails.isNotEmpty
                                      ? 'Edit Remaining Payment Details'
                                      : 'Enter Remaining Payment Details',
                                ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(
                                    0xFF2F2B6E,
                                  ).withOpacity(0.1),
                                  foregroundColor: const Color(0xFF2F2B6E),
                                ),
                              ),
                              if (remainingPaymentDetails.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: theme
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: theme.colorScheme.outline
                                          .withOpacity(0.2),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Remaining Payment Details:',
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      const SizedBox(height: 8),
                                      ...remainingPaymentDetails.entries.map((
                                        entry,
                                      ) {
                                        if (entry.value == null ||
                                            entry.value.toString().isEmpty) {
                                          return const SizedBox.shrink();
                                        }
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 4,
                                          ),
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${entry.key}: ',
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                              Expanded(
                                                child: Text(
                                                  entry.value.toString(),
                                                  style:
                                                      theme.textTheme.bodySmall,
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      }).toList(),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(null),
                          child: const Text('Cancel'),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF2F2B6E),
                          ),
                        ),
                        FilledButton(
                          onPressed: () {
                            final amount = double.tryParse(
                              amountController.text,
                            );
                            if (amount == null || amount <= 0) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text('Please enter a valid amount'),
                                ),
                              );
                              return;
                            }
                            if (amount > totalAmount) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Amount cannot exceed total: Rs. ${totalAmount.toStringAsFixed(2)}',
                                  ),
                                ),
                              );
                              return;
                            }
                            if (hasRemaining &&
                                selectedRemainingPaymentMethod == null) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Please select a payment method for the remaining amount',
                                  ),
                                ),
                              );
                              return;
                            }
                            final remainingPaymentMethod = hasRemaining
                                ? selectedRemainingPaymentMethod
                                : null;
                            Navigator.of(dialogContext).pop({
                              'Amount': amount,
                              'RemainingAmount': remainingAmount,
                              'RemainingPaymentMethod': remainingPaymentMethod,
                              'RemainingPaymentDetails':
                                  remainingPaymentDetails,
                            });
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF2F2B6E),
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Confirm'),
                        ),
                      ],
                    );
                  },
                );
              },
            ) ??
            {};
        break;

      case 'cheque':
      case 'third_party_cheque':
        // Cheque: Cheque Number (6 digits), Bank, Branch, Cheque Date, Amount
        final chequeNumberController = TextEditingController(
          text: existingDetails?['Cheque Number']?.toString() ?? '',
        );
        final bankController = TextEditingController(
          text: existingDetails?['Bank']?.toString() ?? '',
        );
        final branchController = TextEditingController(
          text: existingDetails?['Branch']?.toString() ?? '',
        );
        DateTime? chequeDate = existingDetails?['Cheque Date'] != null
            ? DateTime.tryParse(existingDetails!['Cheque Date'].toString())
            : DateTime.now();
        final amountController = TextEditingController(
          text:
              existingDetails?['Amount']?.toString() ??
              totalAmount.toStringAsFixed(2),
        );
        final chequeType = paymentMethodId == 'cheque'
            ? 'Cheque'
            : 'Third Party Cheque';
        result =
            await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (dialogContext) {
                return StatefulBuilder(
                  builder: (dialogContext, setDialogState) {
                    String? selectedRemainingPaymentMethod =
                        existingDetails?['RemainingPaymentMethod']
                            ?.toString() ??
                        'cash';
                    // Store remaining payment method details
                    Map<String, dynamic> remainingPaymentDetails =
                        existingDetails?['RemainingPaymentDetails'] ?? {};
                    return AlertDialog(
                      title: Row(
                        children: [
                          Icon(
                            Icons.description_rounded,
                            color: const Color(0xFF2F2B6E),
                          ),
                          const SizedBox(width: 12),
                          Text('$chequeType Payment'),
                        ],
                      ),
                      content: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextField(
                              controller: chequeNumberController,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(6),
                              ],
                              decoration: InputDecoration(
                                labelText: 'Cheque Number (6 digits)',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                prefixIcon: const Icon(Icons.numbers_rounded),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: bankController,
                              decoration: InputDecoration(
                                labelText: 'Bank',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                prefixIcon: const Icon(
                                  Icons.account_balance_rounded,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: branchController,
                              decoration: InputDecoration(
                                labelText: 'Branch',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                prefixIcon: const Icon(
                                  Icons.location_on_rounded,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            InkWell(
                              onTap: () async {
                                final picked = await showDatePicker(
                                  context: dialogContext,
                                  initialDate: chequeDate ?? DateTime.now(),
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime.now(),
                                );
                                if (picked != null) {
                                  setDialogState(() {
                                    chequeDate = picked;
                                  });
                                }
                              },
                              child: InputDecorator(
                                decoration: InputDecoration(
                                  labelText: 'Cheque Date',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  prefixIcon: const Icon(
                                    Icons.calendar_today_rounded,
                                  ),
                                ),
                                child: Text(
                                  chequeDate != null
                                      ? DateFormat(
                                          'MMM dd, yyyy',
                                        ).format(chequeDate!)
                                      : 'Select date',
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: amountController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9.]'),
                                ),
                              ],
                              decoration: InputDecoration(
                                labelText: 'Amount',
                                prefixText: 'Rs. ',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                suffixText:
                                    'of Rs. ${totalAmount.toStringAsFixed(2)}',
                              ),
                              onChanged: (value) {
                                setDialogState(() {});
                              },
                            ),
                            Builder(
                              builder: (context) {
                                final enteredAmount =
                                    double.tryParse(amountController.text) ??
                                    0.0;
                                final remainingAmount =
                                    (totalAmount - enteredAmount).clamp(
                                      0,
                                      double.infinity,
                                    );
                                final hasRemaining = remainingAmount > 0.01;

                                if (!hasRemaining)
                                  return const SizedBox.shrink();

                                return Column(
                                  children: [
                                    const SizedBox(height: 16),
                                    Text(
                                      'Remaining Amount: Rs. ${remainingAmount.toStringAsFixed(2)}',
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                    const SizedBox(height: 8),
                                    DropdownButtonFormField<String>(
                                      value: selectedRemainingPaymentMethod,
                                      decoration: InputDecoration(
                                        labelText:
                                            'Select Payment Method for Remaining *',
                                        hintText: 'Choose Payment',
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        filled: true,
                                        fillColor: Colors.white,
                                        prefixIcon: const Icon(
                                          Icons.payment_rounded,
                                        ),
                                      ),
                                      items: allPaymentMethods.map((method) {
                                        return DropdownMenuItem<String>(
                                          value: method['id'],
                                          child: Row(
                                            children: [
                                              Icon(
                                                _getPaymentIcon(method['id']),
                                                size: 20,
                                                color: const Color(0xFF2F2B6E),
                                              ),
                                              const SizedBox(width: 12),
                                              Text(method['name']),
                                            ],
                                          ),
                                        );
                                      }).toList(),
                                      onChanged: (value) async {
                                        if (value != null) {
                                          setDialogState(() {
                                            selectedRemainingPaymentMethod =
                                                value;
                                            // Clear remaining payment details when method changes
                                            remainingPaymentDetails = {};
                                          });
                                          // Automatically open payment details popup for remaining payment method
                                          final remainingMethod =
                                              allPaymentMethods.firstWhere(
                                                (m) => m['id'] == value,
                                                orElse: () =>
                                                    allPaymentMethods.first,
                                              );
                                          final details =
                                              await _showPaymentDetailsPopup(
                                                dialogContext,
                                                value,
                                                remainingMethod,
                                                remainingAmount.toDouble(),
                                                remainingPaymentDetails,
                                                allPaymentMethods,
                                              );
                                          if (details != null &&
                                              details.containsKey('Amount')) {
                                            setDialogState(() {
                                              // Store only the payment details, not the amount (amount is fixed as remaining)
                                              remainingPaymentDetails =
                                                  Map.from(details);
                                              remainingPaymentDetails.remove(
                                                'Amount',
                                              );
                                              remainingPaymentDetails.remove(
                                                'RemainingAmount',
                                              );
                                              remainingPaymentDetails.remove(
                                                'RemainingPaymentMethod',
                                              );
                                            });
                                          }
                                        }
                                      },
                                    ),
                                    // Show payment details input for remaining payment method
                                    if (selectedRemainingPaymentMethod !=
                                        null) ...[
                                      const SizedBox(height: 16),
                                      FilledButton.icon(
                                        onPressed: () async {
                                          final remainingMethod =
                                              allPaymentMethods.firstWhere(
                                                (m) =>
                                                    m['id'] ==
                                                    selectedRemainingPaymentMethod,
                                                orElse: () =>
                                                    allPaymentMethods.first,
                                              );
                                          final details =
                                              await _showPaymentDetailsPopup(
                                                dialogContext,
                                                selectedRemainingPaymentMethod!,
                                                remainingMethod,
                                                remainingAmount.toDouble(),
                                                remainingPaymentDetails,
                                                allPaymentMethods,
                                              );
                                          if (details != null &&
                                              details.containsKey('Amount')) {
                                            setDialogState(() {
                                              // Store only the payment details, not the amount (amount is fixed as remaining)
                                              remainingPaymentDetails =
                                                  Map.from(details);
                                              remainingPaymentDetails.remove(
                                                'Amount',
                                              );
                                              remainingPaymentDetails.remove(
                                                'RemainingAmount',
                                              );
                                              remainingPaymentDetails.remove(
                                                'RemainingPaymentMethod',
                                              );
                                            });
                                          }
                                        },
                                        icon: const Icon(Icons.edit_rounded),
                                        label: Text(
                                          remainingPaymentDetails.isNotEmpty
                                              ? 'Edit Remaining Payment Details'
                                              : 'Enter Remaining Payment Details',
                                        ),
                                        style: FilledButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF2F2B6E,
                                          ),
                                          foregroundColor: Colors.white,
                                        ),
                                      ),
                                      if (remainingPaymentDetails
                                          .isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        Container(
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: theme
                                                .colorScheme
                                                .surfaceContainerHighest,
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: remainingPaymentDetails
                                                .entries
                                                .map((entry) {
                                                  return Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          vertical: 4,
                                                        ),
                                                    child: Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .spaceBetween,
                                                      children: [
                                                        Text(
                                                          entry.key,
                                                          style: theme
                                                              .textTheme
                                                              .bodyMedium
                                                              ?.copyWith(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w500,
                                                              ),
                                                        ),
                                                        Text(
                                                          entry.value
                                                              .toString(),
                                                          style: theme
                                                              .textTheme
                                                              .bodyMedium,
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                })
                                                .toList(),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(null),
                          child: const Text('Cancel'),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF2F2B6E),
                          ),
                        ),
                        FilledButton(
                          onPressed: () {
                            if (chequeNumberController.text.trim().length !=
                                6) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Cheque number must be 6 digits',
                                  ),
                                ),
                              );
                              return;
                            }
                            if (bankController.text.trim().isEmpty) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text('Please enter bank name'),
                                ),
                              );
                              return;
                            }
                            if (branchController.text.trim().isEmpty) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text('Please enter branch name'),
                                ),
                              );
                              return;
                            }
                            if (chequeDate == null) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text('Please select cheque date'),
                                ),
                              );
                              return;
                            }
                            final amount = double.tryParse(
                              amountController.text,
                            );
                            if (amount == null || amount <= 0) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text('Please enter a valid amount'),
                                ),
                              );
                              return;
                            }
                            if (amount > totalAmount) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Amount cannot exceed total: Rs. ${totalAmount.toStringAsFixed(2)}',
                                  ),
                                ),
                              );
                              return;
                            }
                            final remainingAmount = (totalAmount - amount)
                                .clamp(0, double.infinity);
                            final hasRemaining = remainingAmount > 0.01;
                            if (hasRemaining &&
                                selectedRemainingPaymentMethod == null) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Please select a payment method for the remaining amount',
                                  ),
                                ),
                              );
                              return;
                            }
                            final remainingPaymentMethod = hasRemaining
                                ? selectedRemainingPaymentMethod
                                : null;
                            Navigator.of(dialogContext).pop({
                              'Cheque Number': chequeNumberController.text
                                  .trim(),
                              'Bank': bankController.text.trim(),
                              'Branch': branchController.text.trim(),
                              'Cheque Date': DateFormat(
                                'yyyy-MM-dd',
                              ).format(chequeDate!),
                              'Amount': amount,
                              'RemainingAmount': remainingAmount,
                              'RemainingPaymentMethod': remainingPaymentMethod,
                              'RemainingPaymentDetails':
                                  remainingPaymentDetails,
                            });
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF2F2B6E),
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Confirm'),
                        ),
                      ],
                    );
                  },
                );
              },
            ) ??
            {};
        break;

      case 'cod':
        // COD: COD Number + Amount
        final codNumberController = TextEditingController(
          text: existingDetails?['COD Number']?.toString() ?? '',
        );
        final amountController = TextEditingController(
          text:
              existingDetails?['Amount']?.toString() ??
              totalAmount.toStringAsFixed(2),
        );
        result =
            await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: Row(
                  children: [
                    Icon(
                      Icons.local_shipping_rounded,
                      color: const Color(0xFF2F2B6E),
                    ),
                    const SizedBox(width: 12),
                    const Text('COD Payment'),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: codNumberController,
                      decoration: InputDecoration(
                        labelText: 'COD Number',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        prefixIcon: const Icon(Icons.numbers_rounded),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Amount',
                        prefixText: 'Rs. ',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(null),
                    child: const Text('Cancel'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF2F2B6E),
                    ),
                  ),
                  FilledButton(
                    onPressed: () {
                      if (codNumberController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(
                            content: Text('Please enter COD number'),
                          ),
                        );
                        return;
                      }
                      final amount = double.tryParse(amountController.text);
                      if (amount == null || amount <= 0) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(
                            content: Text('Please enter a valid amount'),
                          ),
                        );
                        return;
                      }
                      Navigator.of(dialogContext).pop({
                        'COD Number': codNumberController.text.trim(),
                        'Amount': amount,
                      });
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2F2B6E),
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Confirm'),
                  ),
                ],
              ),
            ) ??
            {};
        break;

      case 'direct_deposit':
        // Direct Deposit: Deposit Number, Bank, Branch, Amount
        final depositNumberController = TextEditingController(
          text: existingDetails?['Deposit Number']?.toString() ?? '',
        );
        final bankController = TextEditingController(
          text: existingDetails?['Bank']?.toString() ?? '',
        );
        final branchController = TextEditingController(
          text: existingDetails?['Branch']?.toString() ?? '',
        );
        final amountController = TextEditingController(
          text:
              existingDetails?['Amount']?.toString() ??
              totalAmount.toStringAsFixed(2),
        );
        result =
            await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: Row(
                  children: [
                    Icon(
                      Icons.account_balance_wallet_rounded,
                      color: const Color(0xFF2F2B6E),
                    ),
                    const SizedBox(width: 12),
                    const Text('Direct Deposit Payment'),
                  ],
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: depositNumberController,
                        decoration: InputDecoration(
                          labelText: 'Deposit Number',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.numbers_rounded),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: bankController,
                        decoration: InputDecoration(
                          labelText: 'Bank',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.account_balance_rounded),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: branchController,
                        decoration: InputDecoration(
                          labelText: 'Branch',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.location_on_rounded),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: amountController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        decoration: InputDecoration(
                          labelText: 'Amount',
                          prefixText: 'Rs. ',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(null),
                    child: const Text('Cancel'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF2F2B6E),
                    ),
                  ),
                  FilledButton(
                    onPressed: () {
                      if (depositNumberController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(
                            content: Text('Please enter deposit number'),
                          ),
                        );
                        return;
                      }
                      if (bankController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(
                            content: Text('Please enter bank name'),
                          ),
                        );
                        return;
                      }
                      if (branchController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(
                            content: Text('Please enter branch name'),
                          ),
                        );
                        return;
                      }
                      final amount = double.tryParse(amountController.text);
                      if (amount == null || amount <= 0) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(
                            content: Text('Please enter a valid amount'),
                          ),
                        );
                        return;
                      }
                      Navigator.of(dialogContext).pop({
                        'Deposit Number': depositNumberController.text.trim(),
                        'Bank': bankController.text.trim(),
                        'Branch': branchController.text.trim(),
                        'Amount': amount,
                      });
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2F2B6E),
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Confirm'),
                  ),
                ],
              ),
            ) ??
            {};
        break;

      case 'online':
        // Online: Amount only
        final amountController = TextEditingController(
          text:
              existingDetails?['Amount']?.toString() ??
              totalAmount.toStringAsFixed(2),
        );
        result =
            await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: Row(
                  children: [
                    Icon(Icons.payment_rounded, color: const Color(0xFF2F2B6E)),
                    const SizedBox(width: 12),
                    const Text('Online Payment'),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Amount',
                        prefixText: 'Rs. ',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(null),
                    child: const Text('Cancel'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF2F2B6E),
                    ),
                  ),
                  FilledButton(
                    onPressed: () {
                      final amount = double.tryParse(amountController.text);
                      if (amount == null || amount <= 0) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(
                            content: Text('Please enter a valid amount'),
                          ),
                        );
                        return;
                      }
                      Navigator.of(dialogContext).pop({'Amount': amount});
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2F2B6E),
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Confirm'),
                  ),
                ],
              ),
            ) ??
            {};
        break;
    }

    return result.isEmpty ? null : result;
  }

  Future<void> _openPostSalesOrderDialog() async {
    final amountController = TextEditingController();
    final generalDetailsController = TextEditingController();
    Map<String, String>? dialogCustomer = _selectedCustomer != null
        ? Map<String, String>.from(_selectedCustomer!)
        : null;

    if (_rows.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Please add items to the $_documentTitleLower before posting',
            ),
            backgroundColor: _accentColor,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final total = _calculateTotal();
    amountController.text = total.toStringAsFixed(2);

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final theme = Theme.of(context);
            return Dialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 40,
              ),
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.9,
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    // Modern Header
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [_accentColor, _accentColor],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.receipt_long_rounded,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _postDialogTitle,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Review ${_rows.length} items before posting',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.9),
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.white,
                            ),
                            onPressed: () => Navigator.of(context).pop(),
                            tooltip: 'Close',
                          ),
                        ],
                      ),
                    ),
                    // Scrollable Content
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () async {
                                final selection = await _showCustomerDialog();
                                if (selection == null) return;
                                setState(() {
                                  dialogCustomer = selection.isEmpty
                                      ? null
                                      : Map<String, String>.from(selection);
                                });
                              },
                              icon: const Icon(Icons.person_rounded),
                              label: Text(
                                dialogCustomer?['name'] ?? 'Select Customer',
                                overflow: TextOverflow.ellipsis,
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                  horizontal: 16,
                                ),
                                foregroundColor: _accentColor,
                                side: BorderSide(color: _accentColor, width: 1.5),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                            if (dialogCustomer == null) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Select a customer before posting the quotation.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            // Document Items Section
                            Text(
                              _itemsTitle,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Items List (Display only, no payment method selection)
                            Container(
                              constraints: BoxConstraints(
                                maxHeight:
                                    MediaQuery.of(context).size.height * 0.3,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: theme.colorScheme.outline.withOpacity(
                                    0.2,
                                  ),
                                ),
                              ),
                              child: ListView.builder(
                                shrinkWrap: true,
                                itemCount: _rows.length,
                                itemBuilder: (context, index) {
                                  final item = _rows[index];
                                  final price = _getPriceFromRow(item);
                                  final qty =
                                      (item['qty'] as num?)?.toInt() ?? 1;
                                  final discount =
                                      (item['discount'] as String?)?.replaceAll(
                                        RegExp(r'[^0-9.]'),
                                        '',
                                      ) ??
                                      '0';
                                  final discountValue =
                                      double.tryParse(discount) ?? 0.0;
                                  final subtotal = price * qty;
                                  final netAmount = subtotal - discountValue;

                                  return Container(
                                    margin: EdgeInsets.only(
                                      bottom: index < _rows.length - 1 ? 8 : 0,
                                      top: index > 0 ? 8 : 0,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: theme
                                                .colorScheme
                                                .primaryContainer,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Text(
                                            '${index + 1}',
                                            style: TextStyle(
                                              color: theme
                                                  .colorScheme
                                                  .onPrimaryContainer,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                _shortItemLabel(
                                                  item['item'] as String?,
                                                ),
                                                style: theme.textTheme.bodyLarge
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                              const SizedBox(height: 4),
                                              Row(
                                                children: [
                                                  Text(
                                                    'Qty: $qty',
                                                    style: theme
                                                        .textTheme
                                                        .bodySmall,
                                                  ),
                                                  const SizedBox(width: 12),
                                                  Text(
                                                    'Rs ${price.toStringAsFixed(2)}',
                                                    style: theme
                                                        .textTheme
                                                        .bodySmall,
                                                  ),
                                                  if (discountValue > 0) ...[
                                                    const SizedBox(width: 12),
                                                    Text(
                                                      'Disc: Rs ${discountValue.toStringAsFixed(2)}',
                                                      style: theme
                                                          .textTheme
                                                          .bodySmall
                                                          ?.copyWith(
                                                            color: theme
                                                                .colorScheme
                                                                .error,
                                                          ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: theme
                                                .colorScheme
                                                .primaryContainer,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Text(
                                            'Rs ${netAmount.toStringAsFixed(2)}',
                                            style: TextStyle(
                                              color: theme
                                                  .colorScheme
                                                  .onPrimaryContainer,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 16),
                            // Summary Section
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    theme.colorScheme.surfaceContainerHighest,
                                    theme.colorScheme.surfaceContainerHighest
                                        .withOpacity(0.5),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: theme.colorScheme.outline.withOpacity(
                                    0.2,
                                  ),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _summaryTitle,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 16),
                                  TextField(
                                    controller: amountController,
                                    readOnly: true,
                                    decoration: InputDecoration(
                                      labelText: 'Total Amount',
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      prefixText: 'Rs. ',
                                      filled: true,
                                      fillColor: Colors.white,
                                      prefixIcon: Icon(
                                        Icons.attach_money_rounded,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  TextField(
                                    controller: generalDetailsController,
                                    decoration: InputDecoration(
                                      labelText: 'General Remarks (Optional)',
                                      hintText: 'Add any additional notes...',
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      filled: true,
                                      fillColor: Colors.white,
                                      prefixIcon: const Icon(
                                        Icons.note_rounded,
                                      ),
                                    ),
                                    maxLines: 3,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Footer Actions
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        border: Border(
                          top: BorderSide(
                            color: theme.colorScheme.outline.withOpacity(0.2),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close_rounded),
                              label: const Text('Cancel'),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: FilledButton.icon(
                              onPressed: dialogCustomer == null
                                  ? null
                                  : () async {
                                      final selectedCustomer =
                                          Map<String, String>.from(
                                            dialogCustomer!,
                                          );
                                      Navigator.of(context).pop();
                                      if (!mounted) return;
                                      setState(() {
                                        _selectedCustomer = selectedCustomer;
                                      });
                                      context
                                          .read<CartProvider>()
                                          .setCustomerInfo(
                                            name: selectedCustomer['name'],
                                          );
                                      await _postQuotation();
                                    },
                              icon: const Icon(Icons.check_circle_rounded),
                              label: Text(_postButtonLabel),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                backgroundColor: _accentColor,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: Colors.grey.shade300,
                                disabledForegroundColor: Colors.grey.shade600,
                              ),
                            ),
                          ),
                        ],
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
  }

  void _showPendingItemsPreview(
    BuildContext dialogContext,
    List<Map<String, dynamic>> pendingEntries,
    StateSetter setDialogState,
  ) {
    final theme = Theme.of(dialogContext);
    showDialog<void>(
      context: dialogContext,
      builder: (previewContext) {
        return AlertDialog(
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Pending Items'),
              Chip(
                label: Text('${pendingEntries.length} items'),
                backgroundColor: theme.colorScheme.primaryContainer,
                labelStyle: TextStyle(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 60,
          ),
          content: Builder(
            builder: (context) {
              final screenWidth = MediaQuery.of(context).size.width;
              final screenHeight = MediaQuery.of(context).size.height;
              final maxWidth = screenWidth * 0.95;
              final maxHeight = screenHeight * 0.75;
              // Ensure minWidth doesn't exceed maxWidth
              final minWidth = 600.0 < maxWidth ? 600.0 : maxWidth * 0.9;
              final minHeight = 400.0 < maxHeight ? 400.0 : maxHeight * 0.8;

              return ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
                  maxHeight: maxHeight,
                  minWidth: minWidth,
                  minHeight: minHeight,
                ),
                child: SizedBox(
                  width: maxWidth,
                  height: maxHeight,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.vertical,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columnSpacing: 16,
                        dataRowMinHeight: 48,
                        columns: const [
                          DataColumn(label: Text('Item')),
                          DataColumn(label: Text('Item Name')),
                          DataColumn(label: Text('Qty'), numeric: true),
                          DataColumn(label: Text('Free'), numeric: true),
                          DataColumn(label: Text('Disc (Rs.)')),
                          DataColumn(label: Text('Net (Rs.)'), numeric: true),
                          DataColumn(label: Text('Action')),
                        ],
                        rows: pendingEntries
                            .asMap()
                            .entries
                            .map(
                              (entry) => DataRow(
                                cells: [
                                  DataCell(
                                    Text(
                                      _shortItemLabel(
                                        entry.value['item'] as String? ?? '',
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  DataCell(
                                    Text(
                                      entry.value['item']
                                              ?.toString()
                                              .split('•')
                                              .last
                                              .trim() ??
                                          '',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  DataCell(Text('${entry.value['qty']}')),
                                  DataCell(Text('${entry.value['freeQty']}')),
                                  DataCell(
                                    Text(
                                      '${entry.value['discount'] ?? '0.00'}',
                                    ),
                                  ),
                                  DataCell(
                                    Text(
                                      '${(entry.value['price'] as num?)?.toStringAsFixed(2) ?? '0.00'}',
                                    ),
                                  ),
                                  DataCell(
                                    IconButton(
                                      tooltip: 'Remove',
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        size: 20,
                                      ),
                                      onPressed: () {
                                        setDialogState(() {
                                          pendingEntries.removeAt(entry.key);
                                        });
                                        Navigator.of(previewContext).pop();
                                        // If there are still items, show the preview again
                                        if (pendingEntries.isNotEmpty) {
                                          Future.delayed(
                                            const Duration(milliseconds: 100),
                                            () => _showPendingItemsPreview(
                                              dialogContext,
                                              pendingEntries,
                                              setDialogState,
                                            ),
                                          );
                                        }
                                      },
                                      style: IconButton.styleFrom(
                                        foregroundColor:
                                            theme.colorScheme.error,
                                        backgroundColor: theme.colorScheme.error
                                            .withOpacity(0.1),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(previewContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openAddItemDialog() async {
    // Allow adding items before customer selection; customer is chosen when posting.

    // Allow async loader to refresh dialog UI when products finish loading
    void Function(void Function())? _dialogSetState;

    // Load products from ERP asynchronously (do not block the popup)
    if (_products.isEmpty && !_isLoadingProducts) {
      setState(() {
        _isLoadingProducts = true;
      });
      ApiService.getProductsForInvoice()
          .then((products) {
            if (!mounted) return;
            setState(() {
              _products = products;
              _isLoadingProducts = false;
            });
            if (_dialogSetState != null) _dialogSetState!(() {});
            print(
              '✅ Products loaded: ${_products.length} items available for search',
            );
            if (_products.isNotEmpty) {
              print('📋 First product sample: ${_products.first}');
            }
          })
          .catchError((e) {
            if (!mounted) return;
            setState(() {
              _isLoadingProducts = false;
            });
            if (_dialogSetState != null) _dialogSetState!(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Failed to load items.'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 3),
              ),
            );
          });
    }

    final searchController = TextEditingController();
    final qtyController = TextEditingController(text: '1');
    final discountController = TextEditingController(text: '0');
    final freeQtyController = TextEditingController(text: '0');
    String? errorText;
    Map<String, dynamic>? selectedItem;
    List<Map<String, dynamic>> filteredItems = const [];
    bool hasQuery = false;
    String? discountSummary;
    bool useAmountDiscount = false;
    final List<Map<String, dynamic>> pendingEntries = [];

    bool matchesQuery(Map<String, dynamic> item, String query) {
      if (query.isEmpty) return true;
      final lower = query.toLowerCase().trim();
      final code = (item['code']?.toString() ?? '').toLowerCase();
      final name = (item['name']?.toString() ?? '').toLowerCase();
      return code.contains(lower) || name.contains(lower);
    }

    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            _dialogSetState = setDialogState;
            late void Function([Map<String, dynamic>?]) addPendingEntry;
            void refreshSummary() {
              if (selectedItem == null) {
                setDialogState(() {
                  errorText = null;
                  discountSummary = null;
                });
                return;
              }

              final validation = _validateDiscount(
                selectedItem: selectedItem,
                quantityText: qtyController.text,
                freeQuantityText: freeQtyController.text,
                discountText: discountController.text,
                useAmountDiscount: useAmountDiscount,
              );

              setDialogState(() {
                if (validation.errorMessage != null) {
                  errorText = validation.errorMessage;
                  discountSummary = null;
                } else {
                  errorText = null;
                  discountSummary = validation.summary;
                }
              });
            }

            void applyFilter(String query) {
              setDialogState(() {
                final trimmedQuery = query.trim();
                hasQuery = trimmedQuery.isNotEmpty;

                if (trimmedQuery.isEmpty) {
                  filteredItems = _products;
                  print('🔍 Search cleared');
                } else {
                  print(
                    '🔍 Searching for "$trimmedQuery" in ${_products.length} products...',
                  );
                  filteredItems = _products
                      .where((item) => matchesQuery(item, trimmedQuery))
                      .toList();
                  print('✅ Found ${filteredItems.length} matching products');

                  if (filteredItems.isEmpty) {
                    print('⚠️ No products match "$trimmedQuery"');
                  } else {
                    print(
                      '📋 First match: ${filteredItems.first['code']} - ${filteredItems.first['name']}',
                    );
                  }
                }
              });
            }

            void resetForm() {
              qtyController.text = '1';
              freeQtyController.text = '0';
              discountController.text = '0';
              discountSummary = null;
            }

            Future<void> openNumberEntry({
              required String title,
              required TextEditingController controller,
              bool allowDecimal = false,
            }) async {
              final tempController = TextEditingController(
                text: controller.text,
              );
              final result = await showDialog<String?>(
                context: dialogContext,
                builder: (context) {
                  return AlertDialog(
                    title: Text(title),
                    content: TextField(
                      controller: tempController,
                      autofocus: true,
                      keyboardType: allowDecimal
                          ? const TextInputType.numberWithOptions(decimal: true)
                          : TextInputType.number,
                      inputFormatters: allowDecimal
                          ? [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.]'),
                              ),
                            ]
                          : [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(
                          context,
                        ).pop(tempController.text.trim()),
                        child: const Text('Set'),
                      ),
                    ],
                  );
                },
              );

              if (result == null) {
                return;
              }

              setDialogState(() {
                final fallback = allowDecimal ? '0' : '0';
                final value = result.isEmpty ? fallback : result;
                if (allowDecimal) {
                  final parsed = double.tryParse(value);
                  controller.text = parsed == null
                      ? fallback
                      : parsed.toString();
                } else {
                  final parsed = int.tryParse(value);
                  controller.text = parsed == null
                      ? fallback
                      : parsed.toString();
                }
                errorText = null;
              });

              if (selectedItem != null) {
                refreshSummary();
                addPendingEntry();
              }
            }

            addPendingEntry = ([Map<String, dynamic>? tappedItem]) {
              final isFromGridTap = tappedItem != null;
              if (isFromGridTap) {
                selectedItem = tappedItem;
              }

              final validation = _validateDiscount(
                selectedItem: selectedItem,
                quantityText: qtyController.text,
                freeQuantityText: freeQtyController.text,
                discountText: discountController.text,
                useAmountDiscount: useAmountDiscount,
              );

              if (validation.errorMessage != null) {
                setDialogState(() {
                  errorText = validation.errorMessage;
                });
                return;
              }

              setDialogState(() {
                final productCode = selectedItem?['code']?.toString() ?? '';
                final existingIndex = pendingEntries.indexWhere(
                  (entry) => entry['code']?.toString() == productCode,
                );
                final newEntry = {
                  'item': validation.itemLabel,
                  'code': productCode,
                  'qty': validation.quantity,
                  'freeQty': validation.freeQuantity ?? 0,
                  'discount': validation.discountLabel,
                  'price': validation.finalPrice,
                  'unitPrice': selectedItem?['unitPrice'] ?? 0.0,
                  'wholeSalePrice': selectedItem?['wholeSalePrice'] ?? 0.0,
                  'costPrice': selectedItem?['costPrice'] ?? 0.0,
                  'uom': selectedItem?['uom'] ?? 'PCS',
                  'longDescription': selectedItem?['longDescription'] ?? '',
                  'margin': selectedItem?['margin'] ?? 0.0,
                  'packSize': selectedItem?['packSize'] ?? 1.0,
                  'reOrderQty': selectedItem?['reOrderQty'] ?? 0.0,
                  'batchNo': selectedItem?['batchNo'] ?? '',
                  'stockLoca': selectedItem?['stockLoca'] ?? '',
                  'tax': selectedItem?['tax'] ?? 0.0,
                  'serialNo': selectedItem?['serialNo'] ?? '',
                  'warrantyPeriod': selectedItem?['warrantyPeriod'] ?? 0.0,
                  'phase': selectedItem?['phase'] ?? '',
                  'periodDays': selectedItem?['periodDays'] ?? 0.0,
                  'expiryDate': selectedItem?['expiryDate'],
                  'isBatch': selectedItem?['isBatch'] ?? '0',
                  'isExpiry': selectedItem?['isExpiry'] ?? '0',
                  'isSemi': selectedItem?['isSemi'] ?? '0',
                  'isAuthority': selectedItem?['isAuthority'] ?? '0',
                  'avgCostPrice': selectedItem?['avgCostPrice'] ?? 0.0,
                  'avgDiscount': selectedItem?['avgDiscount'] ?? 0.0,
                  'avgOther': selectedItem?['avgOther'] ?? 0.0,
                  'avgVat': selectedItem?['avgVat'] ?? 0.0,
                  'avgMasterCostPrice':
                      selectedItem?['avgMasterCostPrice'] ?? 0.0,
                  'refCode': selectedItem?['refCode'],
                };

                if (existingIndex >= 0) {
                  final existing = pendingEntries[existingIndex];
                  if (isFromGridTap) {
                    existing['qty'] =
                        ((existing['qty'] as num?)?.toInt() ?? 0) +
                        (validation.quantity ?? 0);
                    existing['freeQty'] =
                        ((existing['freeQty'] as num?)?.toInt() ?? 0) +
                        (validation.freeQuantity ?? 0);
                  } else {
                    existing['qty'] = validation.quantity ?? 0;
                    existing['freeQty'] = validation.freeQuantity ?? 0;
                  }
                  existing['discount'] = validation.discountLabel;
                  existing['price'] = validation.finalPrice;
                } else {
                  pendingEntries.add(newEntry);
                }
                errorText = null;
                discountSummary = validation.summary;
              });
              
              if (isFromGridTap) {
                resetForm();
              }
            };

            final visibleItems = hasQuery ? filteredItems : _products;
            final screenSize = MediaQuery.sizeOf(dialogContext);
            final dialogWidth = (screenSize.width - 16).clamp(320.0, 980.0);
            final dialogHeight = screenSize.height * 0.96;

            return AlertDialog(
              title: const Text('Add Item'),
              contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              content: SizedBox(
                width: dialogWidth,
                height: dialogHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: searchController,
                      decoration: const InputDecoration(
                        hintText: 'Search item by code or name',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                      onChanged: (value) => applyFilter(value),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      flex: 8,
                      child: _isLoadingProducts
                          ? const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(),
                                  SizedBox(height: 8),
                                  Text('Loading products...'),
                                ],
                              ),
                            )
                          : _products.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.inventory_2_outlined,
                                    size: 48,
                                    color: theme.colorScheme.error,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'No products available',
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Please check your database connection',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            )
                          : Material(
                              color: Colors.transparent,
                              child: visibleItems.isEmpty
                                  ? Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(16.0),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.search_off_rounded,
                                              size: 48,
                                              color: theme.colorScheme.onSurface
                                                  .withOpacity(0.5),
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              hasQuery
                                                  ? 'No items match your search'
                                                  : 'No products available',
                                              style: theme.textTheme.bodyMedium,
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              hasQuery
                                                  ? 'Try searching by product code or name'
                                                  : 'Please check your database connection',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onSurface
                                                        .withOpacity(0.7),
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  : GridView.builder(
                                      padding: EdgeInsets.zero,
                                      gridDelegate:
                                          const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 2,
                                        crossAxisSpacing: 10,
                                        mainAxisSpacing: 10,
                                        childAspectRatio: 0.68,
                                      ),
                                      itemCount: visibleItems.length,
                                      itemBuilder: (context, index) {
                                        final item = visibleItems[index];
                                        final isSelected =
                                            selectedItem != null &&
                                            selectedItem!['code'] ==
                                                item['code'];
                                        return InkWell(
                                          onTap: () {
                                            // Pass item directly — avoids setState/search race
                                            // that left selectedItem stale on some pages.
                                            qtyController.text = '1';
                                            freeQtyController.text = '0';
                                            discountController.text = '0';
                                            useAmountDiscount = false;
                                            addPendingEntry(item);
                                          },
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              border: Border.all(
                                                color: isSelected
                                                    ? theme.colorScheme.primary
                                                    : theme.colorScheme.outline
                                                        .withOpacity(0.3),
                                                width: isSelected ? 2 : 1,
                                              ),
                                              color: isSelected
                                                  ? theme.colorScheme.primary
                                                      .withOpacity(0.08)
                                                  : theme.colorScheme
                                                      .surfaceContainerLowest,
                                            ),
                                            padding: const EdgeInsets.all(6),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                AspectRatio(
                                                  aspectRatio: 1,
                                                  child: ProductImageThumbnail(
                                                    expand: true,
                                                    image: item['image'],
                                                    productCode: item['code']
                                                        ?.toString(),
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  item['code']?.toString() ??
                                                      '',
                                                  style: theme
                                                      .textTheme.labelSmall
                                                      ?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: 11,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                                Text(
                                                  item['name']?.toString() ??
                                                      '',
                                                  style: theme.textTheme
                                                      .bodySmall
                                                      ?.copyWith(fontSize: 11),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                                Text(
                                                  'Rs ${_getPriceForItem(item).toStringAsFixed(2)} • ${item['uom']}',
                                                  style: theme
                                                      .textTheme.labelSmall
                                                      ?.copyWith(
                                                    color: theme
                                                        .colorScheme.primary,
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: 10,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      flex: 3,
                      child: SingleChildScrollView(
                        padding: EdgeInsets.zero,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (selectedItem != null)
                              Card(
                                margin: EdgeInsets.zero,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  side: BorderSide(
                                    color: theme.colorScheme.outline
                                        .withOpacity(0.25),
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        selectedItem!['name'] as String,
                                        style: theme.textTheme.titleSmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Code: ${selectedItem!['code']} • UoM: ${selectedItem!['uom']} • Rs ${_getPriceForItem(selectedItem!).toStringAsFixed(2)}',
                                        style: theme.textTheme.bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (selectedItem != null) const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: qtyController,
                                    readOnly: true,
                                    onTap: () => openNumberEntry(
                                      title: 'Enter Quantity',
                                      controller: qtyController,
                                    ),
                                    decoration: const InputDecoration(
                                      labelText: 'Qty',
                                      prefixIcon: Icon(Icons.numbers_rounded),
                                      suffixIcon: Icon(Icons.edit_rounded),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: freeQtyController,
                                    readOnly: true,
                                    onTap: () => openNumberEntry(
                                      title: 'Enter Free Quantity',
                                      controller: freeQtyController,
                                    ),
                                    decoration: const InputDecoration(
                                      labelText: 'Free',
                                      prefixIcon:
                                          Icon(Icons.card_giftcard_rounded),
                                      suffixIcon: Icon(Icons.edit_rounded),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: discountController,
                                    readOnly: true,
                                    onTap: () => openNumberEntry(
                                      title: useAmountDiscount ? 'Enter Flat Discount' : 'Enter Discount (%)',
                                      controller: discountController,
                                      allowDecimal: true,
                                    ),
                                    decoration: InputDecoration(
                                      labelText: useAmountDiscount ? 'Discount (Flat)' : 'Discount (%)',
                                      prefixIcon: Icon(useAmountDiscount ? Icons.money_off_rounded : Icons.percent_rounded),
                                      suffixIcon: const Icon(Icons.edit_rounded),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                IconButton(
                                  onPressed: () {
                                    setDialogState(() {
                                      useAmountDiscount = !useAmountDiscount;
                                      refreshSummary();
                                      if (selectedItem != null) addPendingEntry(selectedItem!);
                                    });
                                  },
                                  icon: Icon(useAmountDiscount ? Icons.percent_rounded : Icons.money_off_rounded),
                                  tooltip: useAmountDiscount ? 'Switch to % Discount' : 'Switch to Flat Discount',
                                  style: IconButton.styleFrom(
                                    backgroundColor: theme.colorScheme.primaryContainer,
                                    foregroundColor: theme.colorScheme.onPrimaryContainer,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (discountSummary != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                discountSummary!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                            if (errorText != null) ...[
                              const SizedBox(height: 10),
                              Text(
                                errorText!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: pendingEntries.isEmpty
                                  ? null
                                  : () {
                                      _showPendingItemsPreview(
                                        dialogContext,
                                        pendingEntries,
                                        setDialogState,
                                      );
                                    },
                              icon: Icon(
                                pendingEntries.isEmpty
                                    ? Icons.shopping_cart_outlined
                                    : Icons.shopping_cart_rounded,
                              ),
                              label: Text(
                                pendingEntries.isEmpty
                                    ? 'No pending items'
                                    : 'View Pending Items (${pendingEntries.length})',
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                  horizontal: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                Row(
                  children: [
                    Expanded(
                      child: IconButton(
                        tooltip: 'Cancel',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close_rounded),
                        style: IconButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                          backgroundColor: theme.colorScheme.error.withOpacity(
                            0.12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: IconButton(
                        tooltip: 'Add & confirm',
                        onPressed: () {
                          if (pendingEntries.isEmpty) {
                            setDialogState(() {
                              errorText =
                                  'Tap an item to add it before confirming.';
                            });
                            return;
                          }

                          Navigator.of(dialogContext).pop({
                            'rows': pendingEntries
                                .map((e) => Map<String, dynamic>.from(e))
                                .toList(),
                            'confirm': true,
                          });
                        },
                        icon: const Icon(Icons.check_circle_rounded),
                        style: IconButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: _accentColor,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );

    if (result != null && mounted) {
      final List<dynamic>? rows = result['rows'] as List<dynamic>?;
      final bool shouldConfirm = result['confirm'] == true;

      if (rows != null && rows.isNotEmpty) {
        setState(() {
          for (final row in rows.cast<Map<String, dynamic>>()) {
            _mergeSalesOrderRow(row);
          }
        });
        _persistActiveDraft();
      }

      if (shouldConfirm && rows != null && rows.isNotEmpty) {
        await _showSalesOrderSummary();
      }
    }
  }

  void _changeRowQuantity(int index, int delta) {
    if (index < 0 || index >= _rows.length) return;
    setState(() {
      final row = _rows[index];
      final currentQty = (row['qty'] as num?)?.toInt() ?? 1;
      final newQty = currentQty + delta;
      if (newQty < 1) return;
      row['qty'] = newQty;
    });
    _persistActiveDraft();
  }

  void _mergeSalesOrderRow(Map<String, dynamic> row) {
    final productCode = row['code']?.toString() ?? '';
    final existingIndex = _rows.indexWhere(
      (entry) => entry['code']?.toString() == productCode,
    );

    if (existingIndex < 0) {
      _rows.add(row);
      return;
    }

    final existing = _rows[existingIndex];
    existing['qty'] =
        ((existing['qty'] as num?)?.toInt() ?? 0) +
        ((row['qty'] as num?)?.toInt() ?? 0);
    existing['freeQty'] =
        ((existing['freeQty'] as num?)?.toInt() ?? 0) +
        ((row['freeQty'] as num?)?.toInt() ?? 0);
    existing['discount'] = row['discount'];
    existing['price'] = row['price'];
  }

  // Calculate subtotal after applying item-wise discounts
  double _calculateSubTotal() {
    return _rows.fold<double>(0, (sum, row) {
      final price = _getPriceFromRow(row);
      final qty = (row['qty'] as num?)?.toInt() ?? 1;
      final itemTotal = price * qty;

      // Apply item-wise discount if present
      final discountStr =
          (row['discount'] as String?)?.replaceAll(RegExp(r'[^0-9.]'), '') ??
          '0';
      final discountValue = double.tryParse(discountStr) ?? 0.0;
      double itemDiscountAmount = 0.0;

      // Check if discount is percentage or amount
      if (row['discount']?.toString().contains('%') == true) {
        itemDiscountAmount = itemTotal * (discountValue / 100);
      } else {
        itemDiscountAmount = discountValue;
      }

      final itemNetTotal = itemTotal - itemDiscountAmount;
      return sum + itemNetTotal;
    });
  }

  // Calculate final total after bill-level discount and taxes
  double _calculateTotal() {
    double subtotal = _calculateSubTotal();

    // Apply bill-level discount
    double billDiscountAmount = _isPercentageDiscount
        ? subtotal * (_salesOrderDiscount / 100)
        : _salesOrderDiscount;

    // Apply discount (but don't go below 0)
    double discountedTotal = (subtotal - billDiscountAmount).clamp(
      0,
      double.infinity,
    );

    // Apply tax calculation based on _selectedTax
    double taxAmount = 0.0;
    if (_selectedTax != null && _selectedTax!.isNotEmpty) {
      // Different tax rates based on tax type (adjust as needed)
      double taxRate = 0.15; // Default VAT rate
      if (_selectedTax!.contains('NBT 1')) {
        taxRate = 0.02; // NBT 1% + VAT 15% = approximate
      } else if (_selectedTax!.contains('NBT 2')) {
        taxRate = 0.02; // NBT 2% + VAT 15% = approximate
      } else if (_selectedTax == 'VAT') {
        taxRate = 0.15; // VAT only
      }
      taxAmount = discountedTotal * taxRate;
    }

    return discountedTotal + taxAmount;
  }

  String _shortItemLabel(String? label) {
    if (label == null || label.isEmpty) return '';
    final parts = label.split('•');
    final trimmed = parts.first.trim();
    return trimmed.length <= 12 ? trimmed : '${trimmed.substring(0, 12)}…';
  }

  Future<void> _showSalesOrderSummary() async {
    if (_rows.isEmpty) {
      return;
    }

    final subtotal = _calculateSubTotal();
    final customer = _selectedCustomer?['name'] ?? 'N/A';
    final quotation = _selectedQuotation?['id'] ?? 'None';
    final poNumber = _poNumberController.text.trim().isNotEmpty
        ? _poNumberController.text.trim()
        : 'None';

    await showDialog<void>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text('Confirm $_documentTitle'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Customer: $customer', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text('Quotation: $quotation', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text('PO#: $poNumber', style: theme.textTheme.bodyMedium),
              const Divider(height: 24),
              Text('Items: ${_rows.length}', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text(
                'Subtotal: Rs ${subtotal.toStringAsFixed(2)}',
                style: theme.textTheme.titleMedium,
              ),
              Text(
                'Full Bill Discount: ${_isPercentageDiscount ? '%' : 'Rs'} ${_salesOrderDiscount.toStringAsFixed(2)}',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Total: Rs ${_calculateTotal().toStringAsFixed(2)}',
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openRemarksDialog() async {
    final tempController = TextEditingController(text: _remarksController.text);
    await showDialog<void>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: const Text('Remarks'),
          content: SizedBox(
            width: double.maxFinite,
            child: TextField(
              controller: tempController,
              autofocus: true,
              maxLines: null,
              minLines: 6,
              decoration: const InputDecoration(
                hintText: 'Type remarks here...',
                border: OutlineInputBorder(),
                isDense: false,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _accentColor,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                if (!mounted) return;
                setState(() {
                  _remarksController.text = tempController.text;
                });
                _persistActiveDraft();
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<Map<String, String>?> _showMockDataDialog({
    required String title,
    required List<Map<String, String>> data,
    required IconData icon,
  }) async {
    if (data.isEmpty) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No records available for selected customer'),
        ),
      );
      return null;
    }
    return showDialog<Map<String, String>?>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: double.maxFinite,
            child: data.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('No records available')),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: data.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final entry = data[index];
                      final id = entry['id'] ?? '';
                      final customer = entry['customer'] ?? '';
                      final date = entry['date'] ?? '';
                      final amount = entry['amount'] ?? '';
                      return ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: theme.colorScheme.outline.withOpacity(0.2),
                          ),
                        ),
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.primaryContainer,
                          foregroundColor: theme.colorScheme.onPrimaryContainer,
                          child: Icon(icon),
                        ),
                        title: Text('$id • $customer'),
                        subtitle: Text('$date • $amount'),
                        onTap: () => Navigator.of(dialogContext).pop(entry),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(<String, String>{}),
              child: const Text('None'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  // ignore: unused_element
  Future<void> _showDateSelectorDialog() async {
    // Initialize dialog state variables
    DateTime? dialogSelectedDate = _selectedDate ?? DateTime.now();

    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            final theme = Theme.of(context);

            return AlertDialog(
              title: const Text('Select Date'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Selected Date',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.outline.withOpacity(0.2),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.calendar_today_rounded,
                          color: const Color(0xFF2F2B6E),
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            DateFormat(
                              'MMM dd, yyyy',
                            ).format(dialogSelectedDate ?? DateTime.now()),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () async {
                      final now = DateTime.now();
                      final pickedDate = await showDatePicker(
                        context: context,
                        initialDate: dialogSelectedDate ?? now,
                        firstDate: DateTime(2020),
                        lastDate: now, // Cannot select future dates
                        builder: (context, child) {
                          return Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: ColorScheme.light(
                                primary: const Color(0xFF2F2B6E),
                                onPrimary: Colors.white,
                              ),
                            ),
                            child: child!,
                          );
                        },
                      );
                      if (pickedDate != null) {
                        setDialogState(() {
                          dialogSelectedDate = pickedDate;
                        });
                      }
                    },
                    icon: const Icon(Icons.edit_calendar_rounded),
                    label: const Text('Select Date'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2F2B6E),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    setDialogState(() {
                      dialogSelectedDate = null;
                    });
                  },
                  child: const Text('Clear'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF2F2B6E),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF2F2B6E),
                  ),
                ),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _selectedDate = dialogSelectedDate;
                    });
                    _persistActiveDraft();
                    Navigator.of(context).pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2F2B6E),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _getDateDisplayText() {
    return DateFormat('MMM dd, yyyy').format(DateTime.now());
  }

  // Helper function to build summary row in bill preview
  Widget _buildSummaryRow(
    String label,
    double amount,
    ThemeData theme, {
    bool isDiscount = false,
    bool isTotal = false,
  }) {
    final formattedAmount = amount < 0
        ? '-Rs. ${amount.abs().toStringAsFixed(2)}'
        : 'Rs. ${amount.toStringAsFixed(2)}';

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: isTotal ? FontWeight.w700 : FontWeight.w500,
            color: isDiscount
                ? Colors.red
                : isTotal
                ? const Color(0xFF2F2B6E)
                : theme.colorScheme.onSurface,
          ),
        ),
        Text(
          formattedAmount,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: isTotal ? FontWeight.w700 : FontWeight.w600,
            color: isDiscount
                ? Colors.red
                : isTotal
                ? const Color(0xFF2F2B6E)
                : theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }

  Future<void> _openDiscountTaxesDialog() async {
    if (_selectedCustomer == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Please select a customer first'),
            backgroundColor: _accentColor,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final discountCtrl = TextEditingController(
      text: _salesOrderDiscount.toString(),
    );

    bool percentageDiscountState = _isPercentageDiscount;
    String? selectedTaxState = _selectedTax;

    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            final theme = Theme.of(context);

            // Helper function to open discount entry popup
            Future<void> openDiscountEntry() async {
              final tempController = TextEditingController(
                text: discountCtrl.text,
              );
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
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]'),
                            ),
                          ],
                          decoration: InputDecoration(
                            labelText: percentageDiscountState
                                ? 'Discount Percentage'
                                : 'Discount Amount',
                            hintText: percentageDiscountState
                                ? 'e.g., 10'
                                : 'e.g., 500.00',
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
                          Navigator.of(
                            dialogContext,
                          ).pop(tempController.text.trim());
                        },
                        child: const Text('Set'),
                      ),
                    ],
                  );
                },
              );

              if (result != null && context.mounted) {
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
                  discountCtrl.text = parsedValue.toStringAsFixed(2);
                  setDialogState(() {});
                }
              }
            }

            return AlertDialog(
              title: const Text('Discount & Taxes'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Modern Segmented Button for Discount Type
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
                      setDialogState(() {
                        percentageDiscountState = newSelection.first;
                      });
                    },
                    style: SegmentedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Discount Entry Field (Read-only, opens popup)
                  Text(
                    percentageDiscountState ? 'Discount (%)' : 'Discount (Rs.)',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: discountCtrl,
                    readOnly: true,
                    onTap: () async {
                      await openDiscountEntry();
                      setDialogState(() {});
                    },
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
                    items:
                        [
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
                      setDialogState(() {
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
                    backgroundColor: const Color(0xFF2F2B6E),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    final discount = discountCtrl.text.trim().isEmpty
                        ? 0.0
                        : double.tryParse(discountCtrl.text.trim()) ?? 0.0;

                    // Calculate values for preview
                    final subtotal = _calculateSubTotal();
                    final billDiscountAmount = percentageDiscountState
                        ? subtotal * (discount / 100)
                        : discount;
                    final discountedTotal = (subtotal - billDiscountAmount)
                        .clamp(0, double.infinity);

                    // Calculate tax (matching _calculateTotal logic)
                    double taxAmount = 0.0;
                    if (selectedTaxState != null &&
                        selectedTaxState!.isNotEmpty) {
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
                              _buildSummaryRow('Full Bill', subtotal, theme),
                              const SizedBox(height: 12),
                              _buildSummaryRow(
                                'Discount ${percentageDiscountState ? '($discount%)' : ''}',
                                -billDiscountAmount,
                                theme,
                                isDiscount: true,
                              ),
                              const SizedBox(height: 12),
                              if (selectedTaxState != null &&
                                  selectedTaxState!.isNotEmpty)
                                _buildSummaryRow(
                                  'Tax (${selectedTaxState})',
                                  taxAmount,
                                  theme,
                                ),
                              if (selectedTaxState != null &&
                                  selectedTaxState!.isNotEmpty)
                                const SizedBox(height: 12),
                              const Divider(),
                              const SizedBox(height: 12),
                              _buildSummaryRow(
                                'Grand Total',
                                grandTotal,
                                theme,
                                isTotal: true,
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(previewContext).pop(),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2F2B6E),
                                foregroundColor: Colors.white,
                              ),
                              onPressed: () {
                                Navigator.of(previewContext).pop();
                                // Update parent widget state
                                if (mounted) {
                                  setState(() {
                                    _salesOrderDiscount = discount;
                                    _isPercentageDiscount =
                                        percentageDiscountState;
                                    _selectedTax = selectedTaxState;
                                  });
                                  _persistActiveDraft();
                                }
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
                  },
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showPaymentMethodDialog(BuildContext context) {
    String? selectedMethod;
    final paymentMethods = [
      'Cash',
      'Master Card',
      'Visa Card',
      'Amex Card',
      'Credit',
      'Cheque',
      'Third Party Cheque',
      'COD',
      'Direct Deposit',
      'Online',
    ];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Payment Method'),
        content: DropdownButtonFormField<String>(
          value: selectedMethod,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          items: paymentMethods.map<DropdownMenuItem<String>>((String value) {
            return DropdownMenuItem<String>(value: value, child: Text(value));
          }).toList(),
          onChanged: (String? newValue) {
            selectedMethod = newValue;
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (selectedMethod != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Posted with $selectedMethod')),
                );
                Navigator.pop(context);
              }
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        title: Text(_documentTitle),
        actions: [
          ProductImageDownloadButton(accentColor: _accentColor),
          // Current date display
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _accentColor, width: 1.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.calendar_today_rounded,
                    size: 18,
                    color: _accentColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _getDateDisplayText(),
                    style: TextStyle(fontSize: 14, color: _accentColor),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Consumer<CartProvider>(
                    builder: (context, cart, _) {
                      final displayLabel =
                          _selectedCustomer?['name'] ?? 'Select Customer';
                      return ElevatedButton.icon(
                        onPressed: () async {
                          final selection = await _showCustomerDialog();
                          if (!mounted || selection == null) return;
                          setState(() {
                            if (selection.isEmpty) {
                              _selectedCustomer = null;
                              _selectedQuotation = null;
                              _selectedSalesOrder = null;
                              cart.setCustomerInfo(name: null);
                            } else {
                              _selectedCustomer = selection;
                              // Clear previous selections when customer changes
                              _selectedQuotation = null;
                              _selectedSalesOrder = null;
                              cart.setCustomerInfo(name: selection['name']);
                            }
                          });
                          // Check for saved data after customer selection
                          _checkForSavedData();
                          _persistActiveDraft();
                        },
                        icon: const Icon(Icons.person_rounded),
                        label: Text(
                          displayLabel,
                          overflow: TextOverflow.ellipsis,
                        ),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            vertical: 16,
                            horizontal: 8,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          backgroundColor: _accentColor,
                          foregroundColor: Colors.white,
                          elevation: 0,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                if (_hasSavedDataForCustomer)
                  IconButton(
                    onPressed: _selectedCustomer == null
                        ? null
                        : _recallTemporaryData,
                    icon: const Icon(Icons.history_rounded),
                    tooltip: 'Recall saved items',
                    iconSize: 22,
                    style: IconButton.styleFrom(
                      padding: const EdgeInsets.all(8),
                      minimumSize: const Size(40, 40),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final selected = await showModalBottomSheet<String>(
                  context: context,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  builder: (context) {
                    return SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            leading: const Icon(Icons.storefront_rounded),
                            title: const Text('Retail'),
                            onTap: () => Navigator.of(context).pop('Retail'),
                          ),
                          ListTile(
                            leading: const Icon(Icons.local_mall_rounded),
                            title: const Text('WholeSale'),
                            onTap: () => Navigator.of(context).pop('WholeSale'),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    );
                  },
                );
                if (selected != null && mounted) {
                  setState(() {
                    _salesType = selected;
                    // Recalculate prices for all existing rows based on new sales type
                    for (var row in _rows) {
                      if (row.containsKey('unitPrice') &&
                          row.containsKey('wholeSalePrice')) {
                        // Price will be recalculated when _getPriceFromRow is called
                        // No need to update row['price'] here as we use _getPriceFromRow
                      }
                    }
                  });
                  _persistActiveDraft();
                }
              },
              icon: const Icon(Icons.sell_rounded),
              label: Text('Sales Type: $_salesType'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                foregroundColor: _accentColor,
                side: BorderSide(color: _accentColor, width: 1.5),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _poNumberController,
                    decoration: InputDecoration(
                      labelText: 'PO#',
                      hintText: 'Enter PO Number',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      prefixIcon: const Icon(Icons.numbers_rounded),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualController,
                    decoration: const InputDecoration(
                      hintText: 'Manual #',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _remarksController,
                    readOnly: true,
                    onTap: _openRemarksDialog,
                    decoration: const InputDecoration(
                      hintText: 'Remarks',
                      border: OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: Icon(Icons.open_in_full_rounded),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(children: []),
            const SizedBox(height: 8),
            Expanded(
              child: Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: LayoutBuilder(
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
                            const DataColumn(
                              label: Text('Free'),
                              numeric: true,
                            ),
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
                            // Pre-calculate totals before mapping rows
                            final totalItemsNet = _calculateSubTotal();
                            final billDiscountAmount = _salesOrderDiscount > 0
                                ? (_isPercentageDiscount
                                      ? totalItemsNet *
                                            (_salesOrderDiscount / 100)
                                      : _salesOrderDiscount)
                                : 0.0;

                            return _rows.asMap().entries.map((entry) {
                              final index = entry.key;
                              final r = entry.value;
                              final price = _getPriceFromRow(r);
                              final qty = (r['qty'] as num?)?.toInt() ?? 1;
                              final itemSubtotal = price * qty;

                              // Calculate item-wise discount amount (shown in "Disc ( Rs. )" column)
                              final discountStr =
                                  (r['discount'] as String?)?.replaceAll(
                                    RegExp(r'[^0-9.]'),
                                    '',
                                  ) ??
                                  '0';
                              final discountValue =
                                  double.tryParse(discountStr) ?? 0.0;
                              final isItemDiscountPercent =
                                  (r['discount'] as String?)?.contains('%') ??
                                  false;
                              final itemDiscountAmount = isItemDiscountPercent
                                  ? itemSubtotal * (discountValue / 100)
                                  : discountValue;

                              // Calculate item net after item-wise discount
                              final itemNetAfterDiscount =
                                  itemSubtotal - itemDiscountAmount;

                              // If bill-level discount exists, merge item discount + bill discount portion
                              double combinedDiscountAmount =
                                  itemDiscountAmount;
                              if (billDiscountAmount > 0 && totalItemsNet > 0) {
                                // Distribute bill discount proportionally based on item net value
                                final itemProportion =
                                    itemNetAfterDiscount / totalItemsNet;
                                final itemBillDiscountPortion =
                                    billDiscountAmount * itemProportion;
                                // Combined discount = item discount + bill discount portion
                                combinedDiscountAmount =
                                    itemDiscountAmount +
                                    itemBillDiscountPortion;
                              }

                              // Final item total (after both item and bill discounts)
                              final itemFinalTotal =
                                  itemSubtotal - combinedDiscountAmount;

                              return DataRow(
                                cells: [
                                  DataCell(
                                    Text(
                                      _shortItemLabel(r['item'] as String?),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  DataCell(
                                    Text(
                                      r['item']
                                              ?.toString()
                                              .split('•')
                                              .last
                                              .trim() ??
                                          '',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  DataCell(
                                    Text(
                                      '${r['qty']}',
                                      textAlign: TextAlign.end,
                                    ),
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
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          IconButton(
                                            tooltip: 'Reduce quantity',
                                            onPressed: qty <= 1
                                                ? null
                                                : () => _changeRowQuantity(
                                                    index,
                                                    -1,
                                                  ),
                                            icon: const Icon(
                                              Icons.remove_rounded,
                                              size: 28,
                                            ),
                                            style: IconButton.styleFrom(
                                              minimumSize: const Size(48, 48),
                                              tapTargetSize: MaterialTapTargetSize
                                                  .shrinkWrap,
                                              iconSize: 28,
                                              foregroundColor: _accentColor,
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: 'Increase quantity',
                                            onPressed: () => _changeRowQuantity(
                                              index,
                                              1,
                                            ),
                                            icon: const Icon(
                                              Icons.add_rounded,
                                              size: 28,
                                            ),
                                            style: IconButton.styleFrom(
                                              minimumSize: const Size(48, 48),
                                              tapTargetSize: MaterialTapTargetSize
                                                  .shrinkWrap,
                                              iconSize: 28,
                                              foregroundColor: _accentColor,
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: 'Remove item',
                                            onPressed: () {
                                              setState(() {
                                                _rows.removeAt(index);
                                              });
                                              _persistActiveDraft();
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text('Item removed'),
                                                  behavior: SnackBarBehavior
                                                      .floating,
                                                  duration: Duration(
                                                    seconds: 2,
                                                  ),
                                                ),
                                              );
                                            },
                                            icon: const Icon(
                                              Icons.delete_outline_rounded,
                                              size: 28,
                                            ),
                                            style: IconButton.styleFrom(
                                              minimumSize: const Size(48, 48),
                                              tapTargetSize: MaterialTapTargetSize
                                                  .shrinkWrap,
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
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _openAddItemDialog,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add Item'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      backgroundColor: _accentColor,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openDiscountTaxesDialog,
                    icon: const Icon(Icons.percent_rounded),
                    label: const Text('Discount & Taxes'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      foregroundColor: _accentColor,
                      side: BorderSide(color: _accentColor, width: 1.5),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton(
                  tooltip: 'Temporary Save',
                  onPressed: _selectedCustomer == null || _rows.isEmpty
                      ? null
                      : _saveTemporaryData,
                  icon: const Icon(Icons.save_rounded),
                  style: IconButton.styleFrom(
                    padding: const EdgeInsets.all(12),
                    minimumSize: const Size(48, 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _rows.clear();
                      });
                      _clearActiveDraft();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Table cleared')),
                      );
                    },
                    child: const Text('Clear'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      foregroundColor: _accentColor,
                      side: BorderSide(color: _accentColor, width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _rows.isEmpty
                        ? null
                        : () => _openPostSalesOrderDialog(),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      backgroundColor: _rows.isEmpty
                          ? Colors.grey.shade300
                          : _accentColor,
                      foregroundColor: _rows.isEmpty
                          ? Colors.grey.shade500
                          : Colors.white,
                    ),
                    child: Text(_isQuotationMode ? 'Post Quotation' : 'Post'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Get icon for payment method
  IconData _getPaymentIcon(String methodId) {
    switch (methodId.toLowerCase()) {
      case 'cash':
        return Icons.money_rounded;
      case 'master_card':
        return Icons.credit_card_rounded;
      case 'visa_card':
        return Icons.credit_card_rounded;
      case 'amex_card':
        return Icons.credit_card_rounded;
      case 'credit':
        return Icons.account_balance_rounded;
      case 'cheque':
        return Icons.description_rounded;
      case 'third_party_cheque':
        return Icons.description_rounded;
      case 'cod':
        return Icons.local_shipping_rounded;
      case 'direct_deposit':
        return Icons.account_balance_wallet_rounded;
      case 'online':
        return Icons.payment_rounded;
      default:
        return Icons.payment_rounded;
    }
  }

  // Map payment method names to payment codes (delegates to PaymentUtils)
  String _getPaymentCode(String? methodName) =>
      PaymentUtils.getPaymentCode(methodName);

  Future<void> _generateQuotationPDF({
    required String documentNo,
    required DateTime documentDate,
    required Map<String, dynamic> customer,
    required List<Map<String, dynamic>> rows,
    required double subtotal,
    required double billDiscountAmount,
    required double discountedAmount,
    required double taxAmount,
    required double netAmount,
    required String? remarks,
    required String salesmanName,
    String? reference,
    required BuildContext context,
  }) async {
    await QuotationPdfGenerator.generatePDF(
      documentNo: documentNo,
      documentDate: documentDate,
      customer: customer,
      rows: rows,
      subtotal: subtotal,
      billDiscountAmount: billDiscountAmount,
      discountedAmount: discountedAmount,
      taxAmount: taxAmount,
      netAmount: netAmount,
      remarks: remarks,
      salesmanName: salesmanName,
      reference: reference,
      getPriceFromRow: _getPriceFromRow,
      context: context,
    );
  }

  // Generate PDF for sales order (delegates to SalesOrderPdfGenerator)
  Future<void> _generateSalesOrderPDF({
    required String documentNo,
    required DateTime documentDate,
    required Map<String, dynamic> customer,
    required List<Map<String, dynamic>> rows,
    required double subtotal,
    required double billDiscountAmount,
    required double discountedAmount,
    required double taxAmount,
    required double netAmount,
    required String? remarks,
    required String salesmanName,
    String? poNumber,
    required BuildContext context,
  }) async {
    await SalesOrderPdfGenerator.generatePDF(
      documentNo: documentNo,
      documentDate: documentDate,
      customer: customer,
      rows: rows,
      subtotal: subtotal,
      billDiscountAmount: billDiscountAmount,
      discountedAmount: discountedAmount,
      taxAmount: taxAmount,
      netAmount: netAmount,
      remarks: remarks,
      salesmanName: salesmanName,
      poNumber: poNumber,
      getPriceFromRow: _getPriceFromRow,
      context: context,
    );
  }

  List<Map<String, dynamic>> _buildSalesOrderTempTransactions({
    required DateTime documentDate,
    required String locaCode,
    required String userName,
  }) {
    return _rows.map((row) {
      final qty =
          (row['qty'] as num?)?.toDouble() ??
          (row['quantity'] as num?)?.toDouble() ??
          0.0;
      final freeQty =
          (row['freeQty'] as num?)?.toDouble() ??
          (row['freeQuantity'] as num?)?.toDouble() ??
          0.0;
      final currentPrice = _getPriceFromRow(row);
      final discountStr =
          (row['discount'] as String?)?.replaceAll(RegExp(r'[^0-9.]'), '') ??
          '0';
      final discountValue = double.tryParse(discountStr) ?? 0.0;
      final itemTotal = currentPrice * qty;
      final isDiscountPercent =
          (row['discount'] as String?)?.contains('%') ?? false;
      final discPer = isDiscountPercent ? discountValue : 0.0;
      final discAmount = isDiscountPercent
          ? itemTotal * (discountValue / 100)
          : discountValue;
      final amount = itemTotal - discAmount;
      final rawName =
          ((row['item']?.toString().split('•').last.trim()) ??
                  (row['name'] ?? ''))
              .toString()
              .trim();

      return {
        'productCode': (row['code'] ?? '').toString().trim(),
        'productDescription': rawName.length > 100
            ? rawName.substring(0, 100)
            : rawName,
        'longDescription': row['longDescription']?.toString().isNotEmpty == true
            ? row['longDescription'].toString()
            : rawName,
        'margin': (row['margin'] as num?)?.toDouble() ?? 0.0,
        'unit': row['uom'] ?? 'PCS',
        'packSize': (row['packSize'] as num?)?.toDouble() ?? 1.0,
        'reOrderQty': (row['reOrderQty'] as num?)?.toDouble() ?? 0.0,
        'qty': qty,
        'pQty': 0.0,
        'sQty': 0.0,
        'bQty': 0.0,
        'freeQty': freeQty,
        'costPrice': (row['costPrice'] as num?)?.toDouble() ?? 0.0,
        'unitPrice': (row['unitPrice'] as num?)?.toDouble() ?? currentPrice,
        'wholeSalePrice':
            (row['wholeSalePrice'] as num?)?.toDouble() ?? currentPrice,
        'batchNo': row['batchNo']?.toString() ?? '',
        'expiryDate': row['expiryDate'],
        'discPer': discPer,
        'discAmount': discAmount,
        'amount': amount,
        'stockLoca': row['stockLoca']?.toString().isNotEmpty == true
            ? row['stockLoca'].toString()
            : locaCode,
        'tax': (row['tax'] as num?)?.toDouble() ?? 0.0,
        'serialNo': row['serialNo']?.toString() ?? '',
        'warrantyPeriod': (row['warrantyPeriod'] as num?)?.toDouble() ?? 0.0,
        'phase': row['phase']?.toString() ?? '',
        'periodDays': (row['periodDays'] as num?)?.toDouble() ?? 0.0,
        'isBatch': row['isBatch']?.toString() ?? '0',
        'isExpiry': row['isExpiry']?.toString() ?? '0',
        'isSemi': row['isSemi']?.toString() ?? '0',
        'isAuthority': row['isAuthority']?.toString() ?? '0',
        'adjustment': 0,
        'avgCostPrice': (row['avgCostPrice'] as num?)?.toDouble() ?? 0.0,
        'avgDiscount': (row['avgDiscount'] as num?)?.toDouble() ?? 0.0,
        'avgOther': (row['avgOther'] as num?)?.toDouble() ?? 0.0,
        'avgVat': (row['avgVat'] as num?)?.toDouble() ?? 0.0,
        'avgMasterCostPrice':
            (row['avgMasterCostPrice'] as num?)?.toDouble() ?? 0.0,
        'refCode': row['refCode']?.toString(),
        'documentDate': documentDate.toIso8601String(),
        'createdUser': userName,
      };
    }).toList();
  }

  // Post sales order using stored procedure
  Future<void> _postSalesOrder(
    BuildContext context,
    List<String?>? selectedPaymentMethods,
    Map<String, dynamic>? paymentDetails,
  ) async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    if (_rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please add items to the sales order'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_selectedCustomer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a customer'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Get salesman and location info
    final salesmanCode = authProvider.salesmanCode;
    final salesmanLocation = authProvider.currentSalesman?.location;

    if (salesmanCode.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Salesman information not available. Please login again.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    Map<String, dynamic>? offlinePostData;

    try {
      // Generate temp document number (use timestamp)
      final tempDocNo = 'TMP${DateTime.now().millisecondsSinceEpoch}';
      final documentDate = DateTime.now();
      final locaCode = salesmanLocation ?? '01';
      final costCenter = '000001'; // Default cost center
      final userName =
          authProvider.currentSalesman?.salesmanName ?? salesmanCode;

      // Calculate totals
      final subtotal = _calculateSubTotal();
      final billDiscountAmount = _isPercentageDiscount
          ? subtotal * (_salesOrderDiscount / 100)
          : _salesOrderDiscount;
      final grossAmount = subtotal;
      final discountedAmount = (subtotal - billDiscountAmount).clamp(
        0,
        double.infinity,
      );

      // Calculate tax amount based on selected tax type
      double taxAmount = 0.0;
      double taxPer = 0.0;
      if (_selectedTax != null && _selectedTax!.isNotEmpty) {
        if (_selectedTax!.contains('NBT 1')) {
          taxPer = 17.0; // NBT 1% + VAT 15% = 16% approximate
        } else if (_selectedTax!.contains('NBT 2')) {
          taxPer = 17.0; // NBT 2% + VAT 15% = 17% approximate
        } else if (_selectedTax == 'VAT') {
          taxPer = 15.0; // VAT only
        }
        taxAmount = discountedAmount * (taxPer / 100);
      }

      final netAmount = discountedAmount + taxAmount;
      final salesOrderTempTransactions = _buildSalesOrderTempTransactions(
        documentDate: documentDate,
        locaCode: locaCode,
        userName: userName,
      );
      final tempTransactions = {
        'tempDocNo': tempDocNo,
        'locaCode': locaCode,
        'costCenter': costCenter,
        'iid': 'SON',
        'transactions': salesOrderTempTransactions,
      };

      // Prepare data for stored procedure
      final postData = {
        'docAction': 'P', // P for Post
        'customerCode': _selectedCustomer!['code'] ?? '',
        'customerName': _selectedCustomer!['name'] ?? '',
        'salesmanCode': salesmanCode,
        'address': _selectedCustomer!['address'] ?? '',
        'iid': 'SON',
        'tempDocNo': tempDocNo,
        'creditPeriod': 30,
        'orgDocNo': '',
        'documentDate': documentDate.toIso8601String(),
        'expecteDate': documentDate.toIso8601String(),
        'poDate': documentDate.toIso8601String(),
        'locaCode': locaCode,
        'manualNo': _manualController.text.trim(),
        'reference': _poNumberController.text.trim(),
        'remarks': _remarksController.text.trim(),
        'grossAmount': grossAmount,
        'discPer': _isPercentageDiscount ? _salesOrderDiscount : 0.0,
        'discAmount': billDiscountAmount,
        'taxPer': taxPer,
        'taxAmount': taxAmount,
        'netAmount': netAmount,
        'costCenter': costCenter,
        'otherCharge': 0.0,
        'recall': false,
        'quoRecall': false,
        'quotation': '',
        'saveDocNo': '',
        'salesType': _salesType,
        'priceLevel': 'Standard',
        'roudAmt': 0.0,
        'sheduled': false,
        'freght': false,
        'orderConfirm': false,
        'userName': userName,
      };
      offlinePostData = {...postData, 'tempTransactions': tempTransactions};

      print(
        '📄 Posting sales order to database - TempDocNo: $tempDocNo, Customer: ${_selectedCustomer!['code']}, Amount: $netAmount',
      );

      await ApiService.insertTempTransactions(
        tempDocNo: tempDocNo,
        locaCode: locaCode,
        costCenter: costCenter,
        iid: 'SON',
        transactions: salesOrderTempTransactions,
      );

      // Call the API to post sales order
      final response = await ApiService.postSalesOrder(postData);

      if (response['success'] == true) {
        final documentNo = response['documentNo'] ?? '';

        print('✅ Sales order posted successfully - Document No: $documentNo');

        // Save document data before clearing
        final savedCustomer = Map<String, dynamic>.from(
          _selectedCustomer ?? {},
        );
        final savedRows = List<Map<String, dynamic>>.from(_rows);
        final savedSubtotal = subtotal;
        final savedBillDiscountAmount = billDiscountAmount;
        final savedDiscountedAmount = discountedAmount;
        final savedTaxAmount = taxAmount;
        final savedNetAmount = netAmount;
        final savedRemarks = _remarksController.text;
        final savedSalesmanName = userName;
        final savedPoNumber = _poNumberController.text.trim();

        // Clear sales order data
        if (mounted) {
          setState(() {
            _rows.clear();
            _selectedCustomer = null;
            _selectedQuotation = null;
            _selectedSalesOrder = null;
            _salesOrderDiscount = 0.0;
            _remarksController.clear();
            _manualController.clear();
            _poNumberController.clear();
          });
          await _clearActiveDraft();
        }

        // Show success popup
        if (mounted && context.mounted) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            barrierColor: Colors.black54,
            builder: (dialogContext) {
              final theme = Theme.of(context);
              return AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.check_circle_rounded,
                        color: Colors.green,
                        size: 48,
                      ),
                    ),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Sales Order Posted Successfully',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Document No: $documentNo',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.7),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
                actions: [
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('OK'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.of(dialogContext).pop();
                          try {
                            await _generateSalesOrderPDF(
                              documentNo: documentNo,
                              documentDate: documentDate,
                              customer: savedCustomer,
                              rows: savedRows,
                              subtotal: savedSubtotal.toDouble(),
                              billDiscountAmount: savedBillDiscountAmount
                                  .toDouble(),
                              discountedAmount: savedDiscountedAmount.toDouble(),
                              taxAmount: savedTaxAmount.toDouble(),
                              netAmount: savedNetAmount.toDouble(),
                              remarks: savedRemarks,
                              salesmanName: savedSalesmanName,
                              poNumber: savedPoNumber.isNotEmpty
                                  ? savedPoNumber
                                  : null,
                              context: this.context,
                            );
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(
                                  content: Text('Failed to generate PDF: $e'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.picture_as_pdf_rounded),
                        label: const Text('Generate PDF'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.blue,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.of(dialogContext).pop();
                          try {
                            final pdfBytes = await ReceiptPdfGenerator.generateReceiptPDF(
                              docType: 'Quotation',
                              documentNo: documentNo,
                              documentDate: documentDate,
                              customer: savedCustomer,
                              rows: savedRows,
                              subtotal: savedSubtotal.toDouble(),
                              billDiscountAmount: savedBillDiscountAmount.toDouble(),
                              discountedAmount: savedDiscountedAmount.toDouble(),
                              taxAmount: savedTaxAmount.toDouble(),
                              netAmount: savedNetAmount.toDouble(),
                              remarks: savedRemarks,
                              salesmanName: savedSalesmanName,
                              poNumber: savedPoNumber.isNotEmpty ? savedPoNumber : null,
                            );
                            if (mounted && context.mounted) {
                              await BluetoothPrinterService.printReceipt(
                                context,
                                pdfBytes,
                              );
                            }
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(
                                  content: Text('Failed to generate receipt: $e'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.receipt_long_rounded),
                        label: const Text('Print Receipt'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.orange,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          );
        }
      } else {
        throw Exception(response['error'] ?? 'Failed to post sales order');
      }
    } catch (e) {
      if (offlinePostData == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to prepare offline sales order: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final localDocNo = await OfflineSyncService.queueSalesOrderPost(
        postData: offlinePostData,
      );
      await _loadPendingSalesOrderCount();

      if (mounted) {
        setState(() {
          _rows.clear();
          _selectedCustomer = null;
          _selectedQuotation = null;
          _selectedSalesOrder = null;
          _salesOrderDiscount = 0.0;
          _remarksController.clear();
          _manualController.clear();
          _poNumberController.clear();
        });
        await _clearActiveDraft();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Offline area. Sales order $localDocNo saved locally.',
            ),
            action: SnackBarAction(
              label: 'Sync Now',
              onPressed: _syncPendingSalesOrders,
            ),
          ),
        );
      }
    }
  }

  Future<void> _postQuotation() async {
    if (!mounted) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    if (_rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please add items to the quotation'),
          backgroundColor: _accentColor,
        ),
      );
      return;
    }

    if (_selectedCustomer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please select a customer'),
          backgroundColor: _accentColor,
        ),
      );
      return;
    }

    final salesmanCode = authProvider.salesmanCode;
    final salesmanLocation = authProvider.currentSalesman?.location;

    if (salesmanCode.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Salesman information not available. Please login again.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      final tempDocNo = 'TMP${DateTime.now().millisecondsSinceEpoch}';
      final documentDate = DateTime.now();
      final locaCode = salesmanLocation ?? '01';
      const costCenter = '000001';
      final userName =
          authProvider.currentSalesman?.salesmanName ?? salesmanCode;

      final subtotal = _calculateSubTotal();
      final billDiscountAmount = _isPercentageDiscount
          ? subtotal * (_salesOrderDiscount / 100)
          : _salesOrderDiscount;
      final grossAmount = subtotal;
      final discountedAmount = (subtotal - billDiscountAmount).clamp(
        0,
        double.infinity,
      );

      double taxAmount = 0.0;
      double taxPer = 0.0;
      if (_selectedTax != null && _selectedTax!.isNotEmpty) {
        if (_selectedTax!.contains('NBT 1')) {
          taxPer = 17.0;
        } else if (_selectedTax!.contains('NBT 2')) {
          taxPer = 17.0;
        } else if (_selectedTax == 'VAT') {
          taxPer = 15.0;
        }
        taxAmount = discountedAmount * (taxPer / 100);
      }

      final netAmount = discountedAmount + taxAmount;
      final quotationTempTransactions = _buildSalesOrderTempTransactions(
        documentDate: documentDate,
        locaCode: locaCode,
        userName: userName,
      );

      await ApiService.insertTempTransactions(
        tempDocNo: tempDocNo,
        locaCode: locaCode,
        costCenter: costCenter,
        iid: 'QUO',
        transactions: quotationTempTransactions,
      );

      final postData = {
        'docAction': 'P',
        'customerCode': _selectedCustomer!['code'] ?? '',
        'customerName': _selectedCustomer!['name'] ?? '',
        'salesmanCode': salesmanCode,
        'address': _selectedCustomer!['address'] ?? '',
        'iid': 'QUO',
        'tempDocNo': tempDocNo,
        'orgDocNo': '',
        'documentDate': documentDate.toIso8601String(),
        'locaCode': locaCode,
        'manualNo': _manualController.text.trim(),
        'reference': _poNumberController.text.trim(),
        'remarks': _remarksController.text.trim(),
        'grossAmount': grossAmount,
        'discPer': _isPercentageDiscount ? _salesOrderDiscount : 0.0,
        'discAmount': billDiscountAmount,
        'taxPer': taxPer,
        'taxAmount': taxAmount,
        'netAmount': netAmount,
        'costCenter': costCenter,
        'otherCharge': 0.0,
        'recall': false,
        'saveDocNo': '',
        'salesType': _salesType,
        'priceLevel': 'Standard',
        'roudAmt': 0.0,
        'userName': userName,
      };

      final response = await ApiService.postQuotation(postData);

      if (response['success'] != true) {
        throw Exception(response['error'] ?? 'Failed to post quotation');
      }

      final documentNo = response['documentNo']?.toString() ?? '';

      final savedCustomer = Map<String, dynamic>.from(_selectedCustomer ?? {});
      final savedRows = List<Map<String, dynamic>>.from(_rows);
      final savedSubtotal = subtotal;
      final savedBillDiscountAmount = billDiscountAmount;
      final savedDiscountedAmount = discountedAmount;
      final savedTaxAmount = taxAmount;
      final savedNetAmount = netAmount;
      final savedRemarks = _remarksController.text.trim();
      final savedSalesmanName = userName;
      final savedReference = _poNumberController.text.trim();

      if (!mounted) return;
      setState(() {
        _rows.clear();
        _selectedCustomer = null;
        _selectedQuotation = null;
        _selectedSalesOrder = null;
        _salesOrderDiscount = 0.0;
        _remarksController.clear();
        _manualController.clear();
        _poNumberController.clear();
      });
      await _clearActiveDraft();

      if (!mounted) return;
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black54,
        builder: (dialogContext) {
          final theme = Theme.of(context);
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.check_circle_rounded,
                    color: Colors.green,
                    size: 48,
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Quotation Posted Successfully',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  documentNo.isNotEmpty
                      ? 'Document No: $documentNo'
                      : 'Quotation posted successfully',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.7),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
            actions: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('OK'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.of(dialogContext).pop();
                      try {
                        await _generateQuotationPDF(
                          documentNo: documentNo.isNotEmpty
                              ? documentNo
                              : 'QUOTATION',
                          documentDate: documentDate,
                          customer: savedCustomer,
                          rows: savedRows,
                          subtotal: savedSubtotal.toDouble(),
                          billDiscountAmount: savedBillDiscountAmount.toDouble(),
                          discountedAmount: savedDiscountedAmount.toDouble(),
                          taxAmount: savedTaxAmount.toDouble(),
                          netAmount: savedNetAmount.toDouble(),
                          remarks: savedRemarks.isNotEmpty ? savedRemarks : null,
                          salesmanName: savedSalesmanName,
                          reference:
                              savedReference.isNotEmpty ? savedReference : null,
                          context: this.context,
                        );
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            SnackBar(
                              content: Text('Failed to generate PDF: $e'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.picture_as_pdf_rounded),
                    label: const Text('Generate PDF'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _accentColor,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to post quotation: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
