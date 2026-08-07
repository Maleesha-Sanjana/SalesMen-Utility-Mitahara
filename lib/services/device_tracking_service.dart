import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

class DeviceRegistrationResult {
  final bool allowed;
  final int isAllowed;
  final String message;
  final int maxAllowed;

  const DeviceRegistrationResult({
    required this.allowed,
    required this.isAllowed,
    required this.message,
    this.maxAllowed = 3,
  });

  factory DeviceRegistrationResult.fromJson(Map<String, dynamic> json) {
    final isAllowedValue = json['isAllowed'];
    final allowedFlag = json['allowed'] == true ||
        isAllowedValue == 1 ||
        isAllowedValue == true;
    return DeviceRegistrationResult(
      allowed: allowedFlag,
      isAllowed: allowedFlag ? 1 : 0,
      message: json['message']?.toString() ?? '',
      maxAllowed: (json['maxAllowed'] as num?)?.toInt() ?? 3,
    );
  }
}

class DeviceTrackingSummary {
  final int maxAllowed;
  final int allowedCount;
  final int pendingCount;
  final List<Map<String, dynamic>> devices;

  const DeviceTrackingSummary({
    required this.maxAllowed,
    required this.allowedCount,
    required this.pendingCount,
    required this.devices,
  });
}

bool deviceIsAllowed(Map<String, dynamic> device) {
  final value = device['isAllowed'];
  return value == 1 || value == true;
}

class DeviceTrackingService {
  static const _deviceIdKey = 'app_device_id';

  static Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_deviceIdKey);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId =
          'dev-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999999)}';
      await prefs.setString(_deviceIdKey, deviceId);
    }
    return deviceId;
  }

  static Future<Map<String, String>> collectDeviceDetails() async {
    final deviceInfo = DeviceInfoPlugin();
    final packageInfo = await PackageInfo.fromPlatform();

    var platform = 'unknown';
    var deviceName = '';
    var deviceModel = '';
    var osVersion = '';

    if (kIsWeb) {
      platform = 'web';
      final web = await deviceInfo.webBrowserInfo;
      deviceName = web.browserName.name;
      deviceModel = web.userAgent ?? 'Web browser';
      osVersion = web.platform ?? '';
    } else if (Platform.isAndroid) {
      platform = 'android';
      final android = await deviceInfo.androidInfo;
      deviceName = android.manufacturer;
      deviceModel = '${android.brand} ${android.model}'.trim();
      osVersion = 'Android ${android.version.release}';
    } else if (Platform.isIOS) {
      platform = 'ios';
      final ios = await deviceInfo.iosInfo;
      deviceName = ios.name;
      deviceModel = ios.utsname.machine;
      osVersion = '${ios.systemName} ${ios.systemVersion}';
    }

    return {
      'deviceName': deviceName,
      'deviceModel': deviceModel,
      'platform': platform,
      'osVersion': osVersion,
      'appVersion': packageInfo.version,
    };
  }

  static Future<DeviceRegistrationResult> registerDevice({
    required String userCode,
    required String userName,
    required bool isAdmin,
    required bool isSuper,
  }) async {
    if (isSuper) {
      return const DeviceRegistrationResult(
        allowed: true,
        isAllowed: 1,
        message: 'Super admin devices are not tracked',
      );
    }

    try {
      final serverReachable = await ApiService.checkHealth();
      if (!serverReachable) {
        return const DeviceRegistrationResult(
          allowed: false,
          isAllowed: 0,
          message: 'Server not reachable. Cannot verify device license.',
        );
      }

      final deviceId = await getDeviceId();
      final details = await collectDeviceDetails();



      final response = await ApiService.withFailover(() {
        return http
            .post(
              Uri.parse('${ApiService.baseUrl}/devices/register'),
              headers: {'Content-Type': 'application/json'},
              body: json.encode({
                'deviceId': deviceId,
                'userCode': userCode,
                'userName': userName,
                'deviceName': details['deviceName'],
                'deviceModel': details['deviceModel'],
                'platform': details['platform'],
                'osVersion': details['osVersion'],
                'appVersion': details['appVersion'],
                'isAdmin': isAdmin,
                'isSuper': isSuper,
              }),
            )
            .timeout(const Duration(seconds: 10));
      });

      final body = json.decode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200) {
        return DeviceRegistrationResult.fromJson(body);
      }

      return DeviceRegistrationResult(
        allowed: false,
        isAllowed: 0,
        message: body['error']?.toString() ?? 'Device registration failed',
      );
    } catch (e) {
      return DeviceRegistrationResult(
        allowed: false,
        isAllowed: 0,
        message: 'Device registration failed: $e',
      );
    }
  }

  static Future<void> deactivateDevice() async {
    try {
      final serverReachable = await ApiService.checkHealth();
      if (!serverReachable) return;

      final deviceId = await getDeviceId();
      await ApiService.withFailover(() {
        return http
            .post(
              Uri.parse('${ApiService.baseUrl}/devices/deactivate'),
              headers: {'Content-Type': 'application/json'},
              body: json.encode({'deviceId': deviceId}),
            )
            .timeout(const Duration(seconds: 10));
      });
    } catch (_) {}
  }

  static Future<DeviceTrackingSummary> getAllDevices() async {
    final response = await ApiService.withFailover(() {
      return http.get(
        Uri.parse('${ApiService.baseUrl}/devices/all'),
      );
    });

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch devices: HTTP ${response.statusCode}');
    }

    final data = json.decode(response.body);
    if (data is List) {
      final devices = data
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      return DeviceTrackingSummary(
        maxAllowed: 3,
        allowedCount: devices.where(deviceIsAllowed).length,
        pendingCount: devices.where((d) => !deviceIsAllowed(d)).length,
        devices: devices,
      );
    }

    final map = Map<String, dynamic>.from(data as Map);
    final devices = (map['devices'] as List? ?? [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();

    return DeviceTrackingSummary(
      maxAllowed: (map['maxAllowed'] as num?)?.toInt() ?? 3,
      allowedCount: (map['allowedCount'] as num?)?.toInt() ??
          (map['approvedCount'] as num?)?.toInt() ??
          devices.where(deviceIsAllowed).length,
      pendingCount: (map['pendingCount'] as num?)?.toInt() ??
          devices.where((d) => !deviceIsAllowed(d)).length,
      devices: devices,
    );
  }

  static Future<void> approveDevice({
    required String deviceId,
    required String approvedBy,
    String? replaceDeviceId,
  }) async {
    final response = await ApiService.withFailover(() {
      return http.post(
        Uri.parse('${ApiService.baseUrl}/devices/approve'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'deviceId': deviceId,
          'approvedBy': approvedBy,
          if (replaceDeviceId != null && replaceDeviceId.isNotEmpty)
            'replaceDeviceId': replaceDeviceId,
        }),
      );
    });

    if (response.statusCode != 200) {
      final body = json.decode(response.body) as Map<String, dynamic>;
      throw Exception(body['error']?.toString() ?? 'Failed to approve device');
    }
  }

  static Future<void> revokeDevice({
    required String deviceId,
    required String revokedBy,
  }) async {
    final response = await ApiService.withFailover(() {
      return http.post(
        Uri.parse('${ApiService.baseUrl}/devices/revoke'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'deviceId': deviceId,
          'revokedBy': revokedBy,
        }),
      );
    });

    if (response.statusCode != 200) {
      final body = json.decode(response.body) as Map<String, dynamic>;
      throw Exception(body['error']?.toString() ?? 'Failed to revoke device');
    }
  }
}
