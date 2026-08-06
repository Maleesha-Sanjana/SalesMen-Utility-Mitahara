import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

class ProductImageSyncProgress {
  const ProductImageSyncProgress({
    required this.completed,
    required this.total,
    required this.downloaded,
    required this.skipped,
    required this.failed,
    this.isRunning = true,
    this.message,
  });

  final int completed;
  final int total;
  final int downloaded;
  final int skipped;
  final int failed;
  final bool isRunning;
  final String? message;

  double get fraction => total <= 0 ? 0 : completed / total;
}

/// Downloads product images to app documents and serves them offline.
class ProductImageCacheService {
  ProductImageCacheService._();

  static const _lastSyncKey = 'product_images_last_sync_ms';
  static const Duration syncInterval = Duration(hours: 1);

  static Timer? _hourlyTimer;
  static bool _syncInFlight = false;
  static Directory? _cacheDir;

  static final ValueNotifier<ProductImageSyncProgress?> progress =
      ValueNotifier<ProductImageSyncProgress?>(null);

  static bool get isSyncing => _syncInFlight;

  /// Call once after login / app start.
  static void startHourlySync() {
    _hourlyTimer?.cancel();
    _hourlyTimer = Timer.periodic(syncInterval, (_) {
      unawaited(syncIfDue(force: false));
    });
    // Kick off shortly after start so UI is ready.
    unawaited(Future<void>.delayed(const Duration(seconds: 3), () {
      syncIfDue(force: false);
    }));
  }

  static void stopHourlySync() {
    _hourlyTimer?.cancel();
    _hourlyTimer = null;
  }

  static Future<Directory> _dir() async {
    if (_cacheDir != null) return _cacheDir!;
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/product_images');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  static String _safeFileName(String productCode) {
    return productCode.trim().replaceAll(RegExp(r'[^\w\-.]+'), '_');
  }

  static Future<File> fileFor(String productCode) async {
    final dir = await _dir();
    return File('${dir.path}/${_safeFileName(productCode)}.img');
  }

  static Future<File?> localImageFile(String? productCode) async {
    final code = productCode?.trim();
    if (code == null || code.isEmpty) return null;
    final file = await fileFor(code);
    if (await file.exists() && await file.length() > 0) return file;
    return null;
  }

  static Future<DateTime?> lastSyncAt() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_lastSyncKey);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<bool> isDue() async {
    final last = await lastSyncAt();
    if (last == null) return true;
    return DateTime.now().difference(last) >= syncInterval;
  }

  static Future<ProductImageSyncProgress?> syncIfDue({
    bool force = false,
  }) async {
    if (!force && !await isDue()) {
      return null;
    }
    // When due (or forced), refresh all images from server.
    return syncAll(force: true);
  }

  /// Manual or hourly download of all product images that exist on the server.
  static Future<ProductImageSyncProgress> syncAll({bool force = true}) async {
    if (_syncInFlight) {
      return progress.value ??
          const ProductImageSyncProgress(
            completed: 0,
            total: 0,
            downloaded: 0,
            skipped: 0,
            failed: 0,
            isRunning: true,
            message: 'Sync already running…',
          );
    }

    _syncInFlight = true;
    var downloaded = 0;
    var skipped = 0;
    var failed = 0;

    void emit({
      required int completed,
      required int total,
      bool running = true,
      String? message,
    }) {
      progress.value = ProductImageSyncProgress(
        completed: completed,
        total: total,
        downloaded: downloaded,
        skipped: skipped,
        failed: failed,
        isRunning: running,
        message: message,
      );
    }

    try {
      emit(completed: 0, total: 0, message: 'Fetching product list…');

      final codes = await ApiService.fetchProductImageCodes();
      if (codes.isEmpty) {
        emit(
          completed: 0,
          total: 0,
          running: false,
          message: 'No product images found on server',
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(
          _lastSyncKey,
          DateTime.now().millisecondsSinceEpoch,
        );
        return progress.value!;
      }

      emit(
        completed: 0,
        total: codes.length,
        message: 'Downloading ${codes.length} images…',
      );

      for (var i = 0; i < codes.length; i++) {
        final code = codes[i];
        try {
          final file = await fileFor(code);
          if (!force && await file.exists() && await file.length() > 0) {
            skipped++;
          } else {
            final ok = await _downloadOne(code, file);
            if (ok) {
              downloaded++;
            } else {
              failed++;
            }
          }
        } catch (e) {
          failed++;
          debugPrint('⚠️ Product image sync failed for $code: $e');
        }

        emit(
          completed: i + 1,
          total: codes.length,
          message: 'Downloading images… (${i + 1}/${codes.length})',
        );
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);

      emit(
        completed: codes.length,
        total: codes.length,
        running: false,
        message:
            'Done: $downloaded downloaded, $skipped cached, $failed failed',
      );
      return progress.value!;
    } catch (e) {
      emit(
        completed: 0,
        total: 0,
        running: false,
        message: 'Sync failed: $e',
      );
      rethrow;
    } finally {
      _syncInFlight = false;
    }
  }

  static Future<bool> _downloadOne(String productCode, File file) async {
    final response = await ApiService.withFailover(() {
      final url = ApiService.productImageFileUrl(productCode);
      return http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    });

    if (response.statusCode != 200) return false;
    if (response.bodyBytes.isEmpty) return false;

    final contentType = response.headers['content-type'] ?? '';
    if (contentType.contains('application/json')) return false;

    await file.writeAsBytes(response.bodyBytes, flush: true);
    return true;
  }
}
