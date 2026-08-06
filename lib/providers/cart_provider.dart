import 'package:flutter/foundation.dart';

class CartProvider extends ChangeNotifier {
  String? _customerName;
  String? _tableNumber;
  String? _seatNumber;

  String? get customerName => _customerName;
  String? get tableNumber => _tableNumber;
  String? get seatNumber => _seatNumber;

  void setCustomerInfo({
    String? name,
    String? tableNumber,
    String? seatNumber,
  }) {
    _customerName = name;
    _tableNumber = tableNumber;
    _seatNumber = seatNumber;
    notifyListeners();
  }

  void clearCart() {
    _customerName = null;
    _tableNumber = null;
    _seatNumber = null;
    notifyListeners();
  }
}
