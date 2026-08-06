import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';
import '../widgets/bluetooth_printer_dialog.dart';

class BluetoothPrinterService {
  static const String _prefKey = 'saved_bluetooth_printer_mac';

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

        // Create a white background image and composite the decoded image on top
        // This fixes the issue where transparent PDF backgrounds print as black on thermal printers
        final printImage = img.Image(width: decodedImage.width, height: decodedImage.height);
        img.fill(printImage, color: img.ColorRgb8(255, 255, 255));
        img.compositeImage(printImage, decodedImage);

        // 3. Generate ESC/POS bytes
        // Using PaperSize.mm80 because 4-inch (104mm) printers generally accept mm80 commands,
        // or we might need a custom profile. Usually, mm80 scales well enough.
        final profile = await CapabilityProfile.load();
        final generator = Generator(PaperSize.mm80, profile);
        
        List<int> bytes = [];
        
        bytes += generator.imageRaster(printImage);
        bytes += generator.feed(2);
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
