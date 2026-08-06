import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import 'api_service.dart';

class LocationService {
  static StreamSubscription<Position>? _positionStream;
  static Timer? _locationTimer;
  static Position? _lastKnownPosition;

  /// Check and request location permissions (including background)
  static Future<bool> requestLocationPermission() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('⚠️ Location services are disabled');
        return false;
      }

      if (!kIsWeb && Platform.isAndroid) {
        return _ensureAndroidLocationPermission();
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        print('⚠️ Location permission not granted: $permission');
        return false;
      }

      return true;
    } catch (e) {
      print('⚠️ Location permission check failed: $e');
      return false;
    }
  }

  static Future<bool> _ensureAndroidLocationPermission() async {
    var status = await Permission.locationWhenInUse.status;
    if (status.isGranted) {
      return true;
    }

    status = await Permission.locationWhenInUse.request();
    if (status.isGranted) {
      return true;
    }

    // Some Android devices report coarse location separately.
    final coarseStatus = await Permission.location.status;
    if (coarseStatus.isGranted) {
      return true;
    }

    print('⚠️ Android location permission not granted: $status');
    return false;
  }

  /// Request background/always location so tracking continues when app is minimized.
  static Future<bool> requestBackgroundLocationPermission() async {
    if (kIsWeb) return true;

    if (!await requestLocationPermission()) {
      return false;
    }

    if (Platform.isAndroid) {
      final alwaysStatus = await Permission.locationAlways.status;
      if (alwaysStatus.isGranted) {
        return true;
      }

      // Android requires foreground permission before background prompt.
      final result = await Permission.locationAlways.request();
      if (result.isGranted) {
        return true;
      }

      print('⚠️ Android background location not granted: $result');
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.always) {
      return true;
    }

    permission = await Geolocator.requestPermission();
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  /// Helps keep the foreground service alive on Android OEM devices.
  static Future<void> requestBatteryOptimizationExemption() async {
    if (kIsWeb || !Platform.isAndroid) return;

    final status = await Permission.ignoreBatteryOptimizations.status;
    if (status.isGranted) return;

    await Permission.ignoreBatteryOptimizations.request();
  }

  /// Prepare device for continuous salesman tracking after login.
  static Future<bool> prepareContinuousTracking() async {
    final backgroundGranted = await requestBackgroundLocationPermission();
    await requestBatteryOptimizationExemption();
    return backgroundGranted;
  }

  /// Mark salesman offline on the server when they log out or close tracking.
  static Future<void> deactivateLocationOnServer(String userCode) async {
    if (userCode.isEmpty) return;

    try {
      await ApiService.withFailover(() {
        return http
            .delete(
              Uri.parse('${ApiService.baseUrl}/location/user/$userCode'),
            )
            .timeout(const Duration(seconds: 5));
      });
      print('✅ Location deactivated on server for: $userCode');
    } catch (e) {
      print('⚠️ Failed to deactivate location on server: $e');
    }
  }

  static Future<Position> _readCurrentPosition({
    required LocationAccuracy accuracy,
    bool forceAndroidLocationManager = false,
  }) async {
    return Geolocator.getCurrentPosition(
      desiredAccuracy: accuracy,
      timeLimit: const Duration(seconds: 20),
      forceAndroidLocationManager: forceAndroidLocationManager,
    );
  }

  /// Capture and save location when admin/salesman logs in.
  static Future<bool> saveLoginLocation(String userCode, String userName) async {
    print('📍 Saving login location for: $userName ($userCode)');

    final result = await captureCurrentLocation();
    if (!result.success || result.position == null) {
      print('❌ Login location capture failed: ${result.message}');
      return false;
    }

    try {
      await sendLocationToServer(userCode, userName, result.position!);
      _lastKnownPosition = result.position;
      print(
        '✅ Login location saved: ${result.position!.latitude}, ${result.position!.longitude}',
      );
      return true;
    } catch (e) {
      print('❌ Failed to save login location: $e');
      return false;
    }
  }

  /// Start tracking user location and send to server
  static Future<void> startLocationTracking(
    String userCode,
    String userName,
  ) async {
    print('🌍 Starting location tracking for: $userName ($userCode)');

    try {
      stopLocationTracking();

      // Check permissions first
      bool hasPermission = await requestLocationPermission();
      if (!hasPermission) {
        print('❌ Location permission denied');
        return;
      }

      // Get initial position
      try {
        final result = await captureCurrentLocation();
        if (!result.success || result.position == null) {
          print('❌ Error getting initial location: ${result.message}');
          return;
        }

        _lastKnownPosition = result.position;
        await sendLocationToServer(userCode, userName, result.position!);
        print(
          '📍 Initial location sent: ${result.position!.latitude}, ${result.position!.longitude}',
        );
      } catch (e) {
        print('❌ Error getting initial location: $e');
        return;
      }

      // Start periodic location updates (every 30 seconds)
      _locationTimer = Timer.periodic(const Duration(seconds: 30), (
        timer,
      ) async {
        try {
          final position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
            timeLimit: const Duration(seconds: 20),
          );

          // Always send location update while app is active so admin sees fresh timestamp
          _lastKnownPosition = position;
          await sendLocationToServer(userCode, userName, position);
          print(
            '📍 Active foreground location updated: ${position.latitude}, ${position.longitude}',
          );
        } catch (e) {
          print('❌ Error updating location: $e');
          // Continue running even if individual updates fail
        }
      });
    } catch (e) {
      print('❌ Failed to start location tracking: $e');
      throw e; // Re-throw to be caught by AuthProvider
    }
  }

  /// Stop location tracking
  static void stopLocationTracking() {
    print('🛑 Stopping location tracking');
    _positionStream?.cancel();
    _locationTimer?.cancel();
    _positionStream = null;
    _locationTimer = null;
    _lastKnownPosition = null;
  }

  /// Send location data to server
  static Future<void> sendLocationToServer(
    String userCode,
    String userName,
    Position position, {
    bool manualCheckIn = false,
    String? address,
  }) async {
    try {
      final locationAddress =
          address ??
          '${position.latitude.toStringAsFixed(6)},${position.longitude.toStringAsFixed(6)}';
      final response = await ApiService.withFailover(() {
        return http
            .post(
              Uri.parse('${ApiService.baseUrl}/location/update'),
              headers: {'Content-Type': 'application/json'},
              body: json.encode({
                'userCode': userCode,
                'userName': userName,
                'latitude': position.latitude,
                'longitude': position.longitude,
                'accuracy': position.accuracy,
                'timestamp': DateTime.now().toIso8601String(),
                'speed': position.speed,
                'heading': position.heading,
                'address': locationAddress,
                'manualCheckIn': manualCheckIn,
                'userType':
                    'Salesman', // Default, server will override based on database
              }),
            )
            .timeout(const Duration(seconds: 10));
      });

      if (response.statusCode == 200) {
        print('✅ Location sent to server successfully');
      } else if (response.statusCode == 404) {
        print('❌ Location endpoint not found on server');
        throw Exception('Location tracking endpoint not available on server');
      } else {
        print('❌ Failed to send location: ${response.statusCode}');
        throw Exception(
          'Failed to send location to server: ${response.statusCode}',
        );
      }
    } catch (e) {
      print('❌ Error sending location to server: $e');
      throw Exception('Location server communication failed: $e');
    }
  }

  /// Get current location once with a helpful error message when it fails.
  static Future<LocationCaptureResult> captureCurrentLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return const LocationCaptureResult(
          message:
              'GPS/Location is turned off on this device. Enable Location in Android settings.',
          canOpenLocationSettings: true,
        );
      }

      if (!kIsWeb && Platform.isAndroid) {
        final granted = await _ensureAndroidLocationPermission();
        if (!granted) {
          final status = await Permission.locationWhenInUse.status;
          if (status.isPermanentlyDenied) {
            return const LocationCaptureResult(
              message:
                  'Location permission is blocked. Open App Settings and allow Location for Sales Man Utility.',
              canOpenSettings: true,
            );
          }
          return const LocationCaptureResult(
            message:
                'Location permission was denied. Tap Allow when Android asks for location access.',
          );
        }
      } else {
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }

        if (permission == LocationPermission.deniedForever) {
          return const LocationCaptureResult(
            message:
                'Location permission is blocked. Open Settings and allow location for Sales Man Utility.',
            canOpenSettings: true,
          );
        }

        if (permission == LocationPermission.denied) {
          return const LocationCaptureResult(
            message: 'Location permission was denied. Please allow location access.',
          );
        }
      }

      final attempts = [
        () => _readCurrentPosition(accuracy: LocationAccuracy.high),
        () => _readCurrentPosition(
          accuracy: LocationAccuracy.high,
          forceAndroidLocationManager: true,
        ),
        () => Geolocator.getLastKnownPosition(
          forceAndroidLocationManager: !kIsWeb && Platform.isAndroid,
        ),
        () => _readCurrentPosition(
          accuracy: LocationAccuracy.medium,
          forceAndroidLocationManager: true,
        ),
        () => _readCurrentPosition(
          accuracy: LocationAccuracy.low,
          forceAndroidLocationManager: true,
        ),
      ];

      for (final attempt in attempts) {
        try {
          final position = await attempt();
          if (position != null) {
            return LocationCaptureResult(position: position);
          }
        } catch (e) {
          print('⚠️ Location attempt failed: $e');
        }
      }

      return const LocationCaptureResult(
        message:
            'Unable to get GPS on this Android device. Turn on Location, go outdoors, and try again.',
        canOpenLocationSettings: true,
      );
    } catch (e) {
      print('❌ Error getting current location: $e');
      return LocationCaptureResult(
        message: 'Failed to get location: $e',
      );
    }
  }

  /// Backward-compatible helper used by older call sites.
  static Future<Position?> getCurrentLocation() async {
    final result = await captureCurrentLocation();
    return result.position;
  }

  /// Get all user locations from server (for admin)
  static Future<List<Map<String, dynamic>>> getAllUserLocations() async {
    try {
      final response = await ApiService.withFailover(() {
        return http.get(
          Uri.parse('${ApiService.baseUrl}/location/all'),
          headers: {'Content-Type': 'application/json'},
        );
      });

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data.cast<Map<String, dynamic>>();
      } else {
        print('❌ Failed to fetch user locations: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('❌ Error fetching user locations: $e');
      return [];
    }
  }

  /// Get customer locations captured during customer creation
  static Future<List<Map<String, dynamic>>> getCustomerLocations() async {
    try {
      final response = await ApiService.withFailover(() {
        return http.get(
          Uri.parse('${ApiService.baseUrl}/customers/locations'),
          headers: {'Content-Type': 'application/json'},
        );
      });

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data.cast<Map<String, dynamic>>();
      } else {
        print('❌ Failed to fetch customer locations: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('❌ Error fetching customer locations: $e');
      return [];
    }
  }

  /// Get all user locations with user types (for super admin only)
  static Future<List<Map<String, dynamic>>>
  getAllUserLocationsWithTypes() async {
    try {
      final response = await ApiService.withFailover(() {
        return http.get(
          Uri.parse('${ApiService.baseUrl}/location/all-with-types'),
          headers: {'Content-Type': 'application/json'},
        );
      });

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data.cast<Map<String, dynamic>>();
      } else {
        print(
          '❌ Failed to fetch user locations with types: ${response.statusCode}',
        );
        return [];
      }
    } catch (e) {
      print('❌ Error fetching user locations with types: $e');
      return [];
    }
  }

  /// Check if location tracking is active
  static bool get isTrackingActive {
    return _locationTimer?.isActive == true;
  }

  /// Get last known position
  static Position? get lastKnownPosition => _lastKnownPosition;
}

class LocationCaptureResult {
  final Position? position;
  final String? message;
  final bool canOpenSettings;
  final bool canOpenLocationSettings;

  const LocationCaptureResult({
    this.position,
    this.message,
    this.canOpenSettings = false,
    this.canOpenLocationSettings = false,
  });

  bool get success => position != null;
}
