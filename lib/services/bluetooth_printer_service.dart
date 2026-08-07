import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';
import 'package:permission_handler/permission_handler.dart';
import '../widgets/bluetooth_printer_dialog.dart';

class BluetoothPrinterService {
  static const String _prefKey = 'saved_bluetooth_printer_mac';

  /// Ensure Bluetooth and Location permissions are granted
  static Future<bool> ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    
    // Android 12+ specific permissions
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    
    // Older Androids need location for bluetooth scanning
    await Permission.locationWhenInUse.request();
    await Permission.bluetooth.request();
    
    return true;
  }

  /// Scan for paired bluetooth devices
  static Future<List<BluetoothInfo>> getPairedPrinters() async {
    return await PrintBluetoothThermal.pairedBluetooths;
  }

  /// Get the saved MAC address from SharedPreferences
  static Future<String?> getSavedPrinterMac() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKey);
  }

  /// Connect to a printer by MAC address and save it
  static Future<bool> connectAndSave(String macAddress) async {
    final isConnected = await PrintBluetoothThermal.connect(macPrinterAddress: macAddress);
    if (isConnected) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, macAddress);
    }
    return isConnected;
  }

  /// Check connection status
  static Future<bool> isConnected() async {
    return await PrintBluetoothThermal.connectionStatus;
  }

  /// Try to auto-connect to the saved printer if one exists
  static Future<bool> autoConnect() async {
    final connected = await isConnected();
    if (connected) return true;

    final mac = await getSavedPrinterMac();
    if (mac != null && mac.isNotEmpty) {
      return await PrintBluetoothThermal.connect(macPrinterAddress: mac);
    }
    return false;
  }

  /// Takes PDF bytes, rasterizes them to an image, converts to ESC/POS, and prints over Bluetooth.
  static Future<void> printReceipt(BuildContext context, Uint8List pdfBytes) async {
    try {
      await ensurePermissions();

      if (!(await isConnected())) {
        if (!(await autoConnect())) {
          if (!context.mounted) return;
          
          // Import BluetoothPrinterDialog dynamically or add import at top
          // Show dialog
          final connected = await showDialog<bool>(
            context: context,
            builder: (ctx) => const BluetoothPrinterDialog(),
          );
          if (connected != true) {
            return; // User cancelled
          }
        }
      }

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Printing receipt...'), duration: Duration(seconds: 1)),
      );

      // 1. Rasterize PDF to image
      // We use a lower DPI (like 200) to keep the image size manageable for bluetooth transfer
      await for (var page in Printing.raster(pdfBytes, dpi: 200)) {
        final imageBytes = await page.toPng();
        
        // 2. Decode the PNG using the 'image' package
        final decodedImage = img.decodeImage(imageBytes);
        if (decodedImage == null) throw Exception("Failed to decode PDF image");

        // We must ensure the width is a multiple of 8 to bypass a bug in esc_pos_utils_plus 2.0.4
        // where it crashes on fixed-length lists if the width isn't divisible by 8.
        final targetWidth = (decodedImage.width + 7) ~/ 8 * 8;
        final printImage = img.Image(width: targetWidth, height: decodedImage.height);
        img.fill(printImage, color: img.ColorRgb8(255, 255, 255));
        img.compositeImage(printImage, decodedImage);

        // 3. Generate ESC/POS bytes
        // Using PaperSize.mm80 because 4-inch (104mm) printers generally accept mm80 commands,
        // or we might need a custom profile. Usually, mm80 scales well enough.
        final profile = await CapabilityProfile.load();
        final generator = Generator(PaperSize.mm80, profile);
        
        List<int> bytes = [];
        
        bytes += generator.imageRaster(printImage);
        bytes += generator.feed(5);
        bytes += generator.cut();

        // 4. Send to printer
        final result = await PrintBluetoothThermal.writeBytes(bytes);
        if (!result) {
          throw Exception("Failed to write bytes to printer");
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Bluetooth Print Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      rethrow;
    }
  }
}
