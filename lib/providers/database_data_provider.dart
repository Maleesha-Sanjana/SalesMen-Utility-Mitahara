import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../models/salesman.dart';
import '../models/customer.dart';

class DatabaseDataProvider extends ChangeNotifier {
  // Data storage
  List<Salesman> _users = [];
  List<Customer> _customers = [];
  final List<Map<String, dynamic>> _mockReceipts = [];
  final List<Map<String, dynamic>> _mockReturns = [];

  // Loading states
  bool _isLoadingUsers = false;

  // Error states
  String? _errorMessage;

  // Mock load guard
  bool _mockLoaded = false;

  // Getters
  List<Salesman> get users => _users;
  List<Customer> get customers => _customers;
  bool get isLoadingUsers => _isLoadingUsers;
  String? get errorMessage => _errorMessage;
  bool get hasError => _errorMessage != null;

  /// Load mock data (no API calls)
  Future<void> loadMockData() async {
    if (_mockLoaded) return; // Already loaded
    _isLoadingUsers = false;
    _errorMessage = null;
    notifyListeners();

    _customers = const [
      Customer(code: 'CUS001', name: 'Lakshan Stores', phone: '0771234567', address: 'Colombo', priceTier: 'RETAIL', creditLimit: 50000, currentOutstanding: 12000),
      Customer(code: 'CUS002', name: 'Nisansala Traders', phone: '0712233445', address: 'Galle', priceTier: 'WHOLESALE', creditLimit: 150000, currentOutstanding: 45000),
      Customer(code: 'CUS003', name: 'Saman Bakers', phone: '0759876543', address: 'Kandy', priceTier: 'RETAIL', creditLimit: 30000, currentOutstanding: 5000),
    ];

    _mockLoaded = true;
    notifyListeners();
  }

  // Mock-only mutations
  void addMockCustomer(Customer customer) {
    _customers = [..._customers.where((c) => c.code != customer.code), customer];
    notifyListeners();
  }

  void addMockReceipt({required String customerCode, required double amount, String? note}) {
    _mockReceipts.add({
      'customerCode': customerCode,
      'amount': amount,
      'note': note,
      'createdAt': DateTime.now(),
    });
    notifyListeners();
  }

  void addMockReturn({required String customerCode, required List<Map<String, dynamic>> items, String? note}) {
    _mockReturns.add({
      'customerCode': customerCode,
      'items': items,
      'note': note,
      'createdAt': DateTime.now(),
    });
    notifyListeners();
  }

  /// Load all users from database
  Future<void> loadUsers() async {
    _isLoadingUsers = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _users = await ApiService.getSalesmen();
      print('✅ Loaded ${_users.length} users from database');
    } catch (e) {
      _errorMessage = 'Failed to load users: $e';
      print('❌ Error loading users: $e');
    }

    _isLoadingUsers = false;
    notifyListeners();
  }

  /// Clear error message
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// Refresh all data
  Future<void> refreshAllData() async {
    print('🔄 Refreshing all data (mock)...');
    await loadMockData();
  }
}
