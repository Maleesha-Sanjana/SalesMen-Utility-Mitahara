import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'offline_auto_sync_service.dart';

class OfflineSyncService {
  static const String _pendingCustomersKey = 'offline_pending_customers';
  static const String _pendingSalesOrdersKey = 'offline_pending_sales_orders';
  static const String _pendingInvoicesKey = 'offline_pending_invoices';
  static const String _pendingCrnsKey = 'offline_pending_crns';
  static const String _customerCodeMapKey = 'offline_customer_code_map';

  static Future<int> getPendingCustomerCount() async {
    final records = await _readPendingCustomers();
    return records.length;
  }

  static Future<int> getPendingSalesOrderCount() async {
    final records = await _readRecords(_pendingSalesOrdersKey);
    return records.length;
  }

  static Future<int> getPendingInvoiceCount() async {
    final records = await _readRecords(_pendingInvoicesKey);
    return records.length;
  }

  static Future<int> getPendingCRNCount() async {
    final records = await _readRecords(_pendingCrnsKey);
    return records.length;
  }

  static Future<int> getTotalPendingCount() async {
    final counts = await Future.wait([
      getPendingCustomerCount(),
      getPendingSalesOrderCount(),
      getPendingInvoiceCount(),
      getPendingCRNCount(),
    ]);
    return counts.fold<int>(0, (total, count) => total + count);
  }

  static Future<List<Map<String, dynamic>>> getPendingDocumentsForRep({
    required String documentType,
    required String salesmanCode,
  }) async {
    final code = salesmanCode.trim();
    if (code.isEmpty) return [];

    final String storageKey;
    switch (documentType) {
      case 'invoice':
        storageKey = _pendingInvoicesKey;
        break;
      case 'sales-order':
        storageKey = _pendingSalesOrdersKey;
        break;
      case 'crn':
        storageKey = _pendingCrnsKey;
        break;
      default:
        return [];
    }

    final records = await _readRecords(storageKey);
    final entries = <Map<String, dynamic>>[];

    for (final record in records) {
      final postData = Map<String, dynamic>.from(
        record['postData'] as Map? ?? {},
      );
      if (postData['salesmanCode']?.toString().trim() != code) continue;

      final createdAt = record['createdAt']?.toString();
      final documentDateRaw = postData['documentDate']?.toString();
      final documentDate = documentDateRaw != null && documentDateRaw.isNotEmpty
          ? DateTime.tryParse(documentDateRaw)?.toIso8601String().split('T').first ??
                createdAt?.split('T').first ??
                '-'
          : createdAt?.split('T').first ?? '-';

      entries.add({
        'documentNo':
            record['localDocNo']?.toString() ??
            postData['orgDocNo']?.toString() ??
            postData['tempDocNo']?.toString() ??
            'Pending',
        'documentDate': documentDate,
        'customerCode': postData['customerCode']?.toString() ?? '',
        'customerName': postData['customerName']?.toString() ??
            postData['customerCode']?.toString() ??
            'Customer',
        'netAmount': postData['netAmount'] ?? 0,
        'balanceAmount': postData['netAmount'] ?? 0,
        'remarks': postData['remarks']?.toString() ?? '',
        'isPendingSync': true,
      });
    }

    entries.sort((a, b) {
      final aDate = a['documentDate']?.toString() ?? '';
      final bDate = b['documentDate']?.toString() ?? '';
      return bDate.compareTo(aDate);
    });

    return entries;
  }

  static Future<OfflineSyncAllResult> syncAllPending() async {
    final customers = await syncPendingCustomers();
    final salesOrders = await syncPendingSalesOrders();
    final invoices = await syncPendingInvoices();
    final crns = await syncPendingCRNs();

    final byType = {
      'customers': customers,
      'salesOrders': salesOrders,
      'invoices': invoices,
      'crns': crns,
    };

    final totalSynced = byType.values.fold<int>(
      0,
      (total, result) => total + result.synced,
    );
    final totalFailed = byType.values.fold<int>(
      0,
      (total, result) => total + result.failed,
    );
    final totalRemaining = byType.values.fold<int>(
      0,
      (total, result) => total + result.remaining,
    );

    String? unreachableMessage;
    for (final result in byType.values) {
      if (result.message != null) {
        unreachableMessage = result.message;
        break;
      }
    }

    return OfflineSyncAllResult(
      totalSynced: totalSynced,
      totalFailed: totalFailed,
      totalRemaining: totalRemaining,
      message: unreachableMessage,
      byType: byType,
    );
  }

  static Future<Map<String, dynamic>> queueCustomerCreate({
    required Map<String, dynamic> payload,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final records = await _readPendingCustomers();
    final timestamp = DateTime.now();
    final localCode =
        'LOCAL-CUS-${timestamp.millisecondsSinceEpoch.toString()}';

    final record = {
      'localCode': localCode,
      'payload': payload,
      'createdAt': timestamp.toIso8601String(),
      'lastError': null,
    };

    records.add(record);
    await prefs.setString(_pendingCustomersKey, json.encode(records));
    _notifyQueueChanged();

    return {
      'code': localCode,
      'name': payload['customerName']?.toString() ?? '',
      'address1': payload['address1']?.toString() ?? '',
      'address3': payload['address3']?.toString() ?? '',
      'mobile': payload['mobile']?.toString() ?? '',
      'customerType': payload['customerType']?.toString() ?? 'Trade',
      'taxGroupCode': payload['taxGroupCode']?.toString() ?? '1',
      'creditLimit': payload['creditLimit'] ?? 0,
      'creditPeriod': payload['creditPeriod'] ?? 0,
      'latitude': payload['latitude'],
      'longitude': payload['longitude'],
      'isOffline': true,
    };
  }

  static Future<List<Map<String, dynamic>>>
  getPendingCustomersForSelection({String salesRepCode = ''}) async {
    final normalizedRep = salesRepCode.trim().toUpperCase();
    final records = await _readPendingCustomers();
    return records
        .map((record) {
          final payload = Map<String, dynamic>.from(
            record['payload'] as Map? ?? {},
          );
          return {
            'code': record['localCode']?.toString() ?? '',
            'name': payload['customerName']?.toString() ?? '',
            'phone': payload['mobile']?.toString() ?? '',
            'address': payload['address1']?.toString() ?? '',
            'contactPerson': payload['contactPerson']?.toString() ?? '',
            'salesRepCode': payload['salesRepCode']?.toString() ?? '',
            'createdSalesman': payload['createdSalesman']?.toString() ??
                payload['salesRepCode']?.toString() ??
                '',
            'latitude': payload['latitude'],
            'longitude': payload['longitude'],
            'isOffline': true,
          };
        })
        .where((customer) {
          if (customer['code'].toString().isEmpty ||
              customer['name'].toString().isEmpty) {
            return false;
          }
          return true;
        })
        .toList();
  }

  static Future<List<Map<String, dynamic>>> getCustomersForSelection({
    required String salesRepCode,
  }) async {
    final serverCustomers = await ApiService.getCustomers(salesRepCode: '');
    final offlineCustomers = await getPendingCustomersForSelection(
      salesRepCode: '',
    );
    final existingCodes = serverCustomers
        .map((customer) => customer['code']?.toString() ?? '')
        .where((value) => value.isNotEmpty)
        .toSet();

    return [
      ...offlineCustomers.where(
        (customer) =>
            !existingCodes.contains(customer['code']?.toString() ?? ''),
      ),
      ...serverCustomers,
    ];
  }

  static Future<String> queueSalesOrderPost({
    required Map<String, dynamic> postData,
  }) async {
    final localDocNo = 'LSO${DateTime.now().millisecondsSinceEpoch}';
    await _appendRecord(_pendingSalesOrdersKey, {
      'localDocNo': localDocNo,
      'postData': {...postData, 'orgDocNo': localDocNo},
      'createdAt': DateTime.now().toIso8601String(),
      'lastError': null,
    });
    return localDocNo;
  }

  static Future<String> queueInvoicePost({
    required Map<String, dynamic> tempTransactions,
    required Map<String, dynamic> tempPayments,
    required Map<String, dynamic> postData,
  }) async {
    final localDocNo = 'LINV${DateTime.now().millisecondsSinceEpoch}';
    final localTempDocNo = 'T$localDocNo';

    await _appendRecord(_pendingInvoicesKey, {
      'localDocNo': localDocNo,
      'tempTransactions': {...tempTransactions, 'tempDocNo': localTempDocNo},
      'tempPayments': {...tempPayments, 'tempDocNo': localTempDocNo},
      'postData': {
        ...postData,
        'tempDocNo': localTempDocNo,
        'orgDocNo': localDocNo,
      },
      'createdAt': DateTime.now().toIso8601String(),
      'lastError': null,
    });

    return localDocNo;
  }

  static Future<String> queueCRNPost({
    required Map<String, dynamic> tempTransactions,
    required Map<String, dynamic> tempPayments,
    required Map<String, dynamic> postData,
  }) async {
    final localDocNo = 'LCRN${DateTime.now().millisecondsSinceEpoch}';
    final localTempDocNo = 'T$localDocNo';

    await _appendRecord(_pendingCrnsKey, {
      'localDocNo': localDocNo,
      'tempTransactions': {...tempTransactions, 'tempDocNo': localTempDocNo},
      'tempPayments': {...tempPayments, 'tempDocNo': localTempDocNo},
      'postData': {
        ...postData,
        'tempDocNo': localTempDocNo,
        'orgDocNo': localDocNo,
      },
      'createdAt': DateTime.now().toIso8601String(),
      'lastError': null,
    });

    return localDocNo;
  }

  static Future<OfflineSyncResult> syncPendingCustomers() async {
    final prefs = await SharedPreferences.getInstance();
    final records = await _readPendingCustomers();

    if (records.isEmpty) {
      return const OfflineSyncResult(synced: 0, failed: 0, remaining: 0);
    }

    final serverAvailable = await ApiService.checkHealth();
    if (!serverAvailable) {
      return OfflineSyncResult(
        synced: 0,
        failed: records.length,
        remaining: records.length,
        message: 'Server is not reachable',
      );
    }

    var synced = 0;
    var failed = 0;
    final remaining = <Map<String, dynamic>>[];

    for (final record in records) {
      final payload = Map<String, dynamic>.from(
        record['payload'] as Map? ?? {},
      );

      try {
        final createdCustomer = await ApiService.createCustomer(
          customerName: payload['customerName']?.toString() ?? '',
          location: payload['location']?.toString() ?? '',
          latitude: payload['latitude'] is num
              ? (payload['latitude'] as num).toDouble()
              : null,
          longitude: payload['longitude'] is num
              ? (payload['longitude'] as num).toDouble()
              : null,
          mobile: payload['mobile']?.toString() ?? '',
          customerId: payload['customerId']?.toString() ?? '',
          address1: payload['address1']?.toString() ?? '',
          address2: payload['address2']?.toString() ?? '',
          address3: payload['address3']?.toString() ?? '',
          customerType: payload['customerType']?.toString() ?? 'Trade',
          taxGroupCode: payload['taxGroupCode']?.toString() ?? '1',
          creditLimit: payload['creditLimit'] is num
              ? (payload['creditLimit'] as num).toDouble()
              : double.tryParse(payload['creditLimit']?.toString() ?? '') ?? 0,
          creditPeriod: payload['creditPeriod'] is num
              ? (payload['creditPeriod'] as num).toDouble()
              : double.tryParse(payload['creditPeriod']?.toString() ?? '') ?? 0,
          contactPerson: payload['contactPerson']?.toString() ?? '',
          companyName: payload['companyName']?.toString() ?? '',
          salesRepCode: payload['salesRepCode']?.toString() ?? '',
          createdSalesman: payload['createdSalesman']?.toString() ??
              payload['salesRepCode']?.toString() ??
              '',
          costCenter: payload['costCenter']?.toString() ?? '000001',
          createdUser: payload['createdUser']?.toString() ?? '',
        );
        final localCode = record['localCode']?.toString() ?? '';
        final customerData =
            createdCustomer['customer'] as Map? ?? createdCustomer;
        final serverCode =
            customerData['code']?.toString() ??
            createdCustomer['customerCode']?.toString() ??
            '';
        if (localCode.isNotEmpty && serverCode.isNotEmpty) {
          await _saveCustomerCodeMapping(localCode, serverCode);
        }
        synced += 1;
      } catch (e) {
        failed += 1;
        remaining.add({...record, 'lastError': e.toString()});
      }
    }

    await prefs.setString(_pendingCustomersKey, json.encode(remaining));

    return OfflineSyncResult(
      synced: synced,
      failed: failed,
      remaining: remaining.length,
    );
  }

  static Future<OfflineSyncResult> syncPendingSalesOrders() async {
    final records = await _readRecords(_pendingSalesOrdersKey);
    if (records.isEmpty) {
      return const OfflineSyncResult(synced: 0, failed: 0, remaining: 0);
    }

    final serverAvailable = await ApiService.checkHealth();
    if (!serverAvailable) {
      return OfflineSyncResult(
        synced: 0,
        failed: records.length,
        remaining: records.length,
        message: 'Server is not reachable',
      );
    }

    var synced = 0;
    var failed = 0;
    final remaining = <Map<String, dynamic>>[];

    for (final record in records) {
      final postData = Map<String, dynamic>.from(
        record['postData'] as Map? ?? {},
      );
      try {
        await _resolveQueuedCustomerCode(postData);
        final tempTransactionsRaw = postData.remove('tempTransactions');
        if (tempTransactionsRaw is Map) {
          final tempTransactions = Map<String, dynamic>.from(
            tempTransactionsRaw,
          );
          await ApiService.insertTempTransactions(
            tempDocNo: tempTransactions['tempDocNo']?.toString() ?? '',
            locaCode: tempTransactions['locaCode']?.toString() ?? '01',
            costCenter: tempTransactions['costCenter']?.toString() ?? '000001',
            iid: tempTransactions['iid']?.toString() ?? 'SON',
            transactions: (tempTransactions['transactions'] as List? ?? [])
                .map((item) => Map<String, dynamic>.from(item as Map))
                .toList(),
          );
        }

        final response = await ApiService.postSalesOrder(postData);
        if (response['success'] == true) {
          synced += 1;
        } else {
          throw Exception(response['error'] ?? 'Failed to sync sales order');
        }
      } catch (e) {
        failed += 1;
        remaining.add({...record, 'lastError': e.toString()});
      }
    }

    await _writeRecords(_pendingSalesOrdersKey, remaining);
    return OfflineSyncResult(
      synced: synced,
      failed: failed,
      remaining: remaining.length,
    );
  }

  static Future<OfflineSyncResult> syncPendingInvoices() async {
    final records = await _readRecords(_pendingInvoicesKey);
    if (records.isEmpty) {
      return const OfflineSyncResult(synced: 0, failed: 0, remaining: 0);
    }

    final serverAvailable = await ApiService.checkHealth();
    if (!serverAvailable) {
      return OfflineSyncResult(
        synced: 0,
        failed: records.length,
        remaining: records.length,
        message: 'Server is not reachable',
      );
    }

    var synced = 0;
    var failed = 0;
    final remaining = <Map<String, dynamic>>[];

    for (final record in records) {
      try {
        final tempTransactions = Map<String, dynamic>.from(
          record['tempTransactions'] as Map? ?? {},
        );
        final tempPayments = Map<String, dynamic>.from(
          record['tempPayments'] as Map? ?? {},
        );
        final postData = Map<String, dynamic>.from(
          record['postData'] as Map? ?? {},
        );

        await _resolveQueuedCustomerCode(postData);
        await ApiService.insertTempTransactions(
          tempDocNo: tempTransactions['tempDocNo']?.toString() ?? '',
          locaCode: tempTransactions['locaCode']?.toString() ?? '01',
          costCenter: tempTransactions['costCenter']?.toString() ?? '000001',
          iid: tempTransactions['iid']?.toString() ?? 'INV',
          transactions: (tempTransactions['transactions'] as List? ?? [])
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList(),
        );
        await ApiService.insertTempPayments(
          tempDocNo: tempPayments['tempDocNo']?.toString() ?? '',
          locaCode: tempPayments['locaCode']?.toString() ?? '01',
          payments: (tempPayments['payments'] as List? ?? [])
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList(),
        );
        await ApiService.postInvoicePayload(postData);
        synced += 1;
      } catch (e) {
        failed += 1;
        remaining.add({...record, 'lastError': e.toString()});
      }
    }

    await _writeRecords(_pendingInvoicesKey, remaining);
    return OfflineSyncResult(
      synced: synced,
      failed: failed,
      remaining: remaining.length,
    );
  }

  static Future<OfflineSyncResult> syncPendingCRNs() async {
    final records = await _readRecords(_pendingCrnsKey);
    if (records.isEmpty) {
      return const OfflineSyncResult(synced: 0, failed: 0, remaining: 0);
    }

    final serverAvailable = await ApiService.checkHealth();
    if (!serverAvailable) {
      return OfflineSyncResult(
        synced: 0,
        failed: records.length,
        remaining: records.length,
        message: 'Server is not reachable',
      );
    }

    var synced = 0;
    var failed = 0;
    final remaining = <Map<String, dynamic>>[];

    for (final record in records) {
      try {
        final tempTransactions = Map<String, dynamic>.from(
          record['tempTransactions'] as Map? ?? {},
        );
        final tempPayments = Map<String, dynamic>.from(
          record['tempPayments'] as Map? ?? {},
        );
        final postData = Map<String, dynamic>.from(
          record['postData'] as Map? ?? {},
        );

        await _resolveQueuedCustomerCode(postData);
        await ApiService.insertTempTransactions(
          tempDocNo: tempTransactions['tempDocNo']?.toString() ?? '',
          locaCode: tempTransactions['locaCode']?.toString() ?? '01',
          costCenter: tempTransactions['costCenter']?.toString() ?? '000001',
          iid: tempTransactions['iid']?.toString() ?? 'CRN',
          transactions: (tempTransactions['transactions'] as List? ?? [])
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList(),
        );
        await ApiService.insertTempPayments(
          tempDocNo: tempPayments['tempDocNo']?.toString() ?? '',
          locaCode: tempPayments['locaCode']?.toString() ?? '01',
          payments: (tempPayments['payments'] as List? ?? [])
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList(),
        );
        await ApiService.postCRNPayload(postData);
        synced += 1;
      } catch (e) {
        failed += 1;
        remaining.add({...record, 'lastError': e.toString()});
      }
    }

    await _writeRecords(_pendingCrnsKey, remaining);
    return OfflineSyncResult(
      synced: synced,
      failed: failed,
      remaining: remaining.length,
    );
  }

  static Future<List<Map<String, dynamic>>> _readPendingCustomers() async {
    return _readRecords(_pendingCustomersKey);
  }

  static Future<void> _appendRecord(
    String key,
    Map<String, dynamic> record,
  ) async {
    final records = await _readRecords(key);
    records.add(record);
    await _writeRecords(key, records);
    _notifyQueueChanged();
  }

  static void _notifyQueueChanged() {
    OfflineAutoSyncService.instance.scheduleSyncAttempt();
  }

  static Future<void> _writeRecords(
    String key,
    List<Map<String, dynamic>> records,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, json.encode(records));
  }

  static Future<List<Map<String, dynamic>>> _readRecords(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return [];

    final decoded = json.decode(raw) as List<dynamic>;
    return decoded
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  static Future<void> _resolveQueuedCustomerCode(
    Map<String, dynamic> postData,
  ) async {
    final customerCode = postData['customerCode']?.toString() ?? '';
    if (!customerCode.startsWith('LOCAL-CUS-')) return;

    final codeMap = await _readCustomerCodeMap();
    final serverCode = codeMap[customerCode];
    if (serverCode == null || serverCode.isEmpty) {
      throw Exception('Customer $customerCode is not synced yet');
    }

    postData['customerCode'] = serverCode;
  }

  static Future<Map<String, String>> _readCustomerCodeMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_customerCodeMapKey);
    if (raw == null || raw.isEmpty) return {};

    final decoded = json.decode(raw) as Map<String, dynamic>;
    return decoded.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
  }

  static Future<void> _saveCustomerCodeMapping(
    String localCode,
    String serverCode,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final codeMap = await _readCustomerCodeMap();
    codeMap[localCode] = serverCode;
    await prefs.setString(_customerCodeMapKey, json.encode(codeMap));
  }
}

class OfflineSyncResult {
  const OfflineSyncResult({
    required this.synced,
    required this.failed,
    required this.remaining,
    this.message,
  });

  final int synced;
  final int failed;
  final int remaining;
  final String? message;
}

class OfflineSyncAllResult {
  const OfflineSyncAllResult({
    required this.totalSynced,
    required this.totalFailed,
    required this.totalRemaining,
    required this.byType,
    this.message,
  });

  final int totalSynced;
  final int totalFailed;
  final int totalRemaining;
  final String? message;
  final Map<String, OfflineSyncResult> byType;
}
