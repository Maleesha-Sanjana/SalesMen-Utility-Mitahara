import 'package:flutter/material.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import '../services/bluetooth_printer_service.dart';

class BluetoothPrinterDialog extends StatefulWidget {
  const BluetoothPrinterDialog({Key? key}) : super(key: key);

  @override
  State<BluetoothPrinterDialog> createState() => _BluetoothPrinterDialogState();
}

class _BluetoothPrinterDialogState extends State<BluetoothPrinterDialog> {
  List<BluetoothInfo> _printers = [];
  bool _isLoading = true;
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    _loadPrinters();
  }

  Future<void> _loadPrinters() async {
    setState(() => _isLoading = true);
    try {
      await BluetoothPrinterService.ensurePermissions();
      final printers = await BluetoothPrinterService.getPairedPrinters();
      if (mounted) {
        setState(() {
          _printers = printers;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading printers: $e')),
        );
      }
    }
  }

  Future<void> _connect(String mac) async {
    setState(() => _isConnecting = true);
    try {
      final success = await BluetoothPrinterService.connectAndSave(mac);
      if (mounted) {
        setState(() => _isConnecting = false);
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Printer connected successfully!'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.of(context).pop(true);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to connect to printer.'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isConnecting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('Select Bluetooth Printer'),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isConnecting || _isLoading ? null : _loadPrinters,
            tooltip: 'Reload Printers',
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 300,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _printers.isEmpty
                ? const Center(
                    child: Text(
                      'No paired Bluetooth printers found.\nPlease pair the printer in your device settings first.',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    itemCount: _printers.length,
                    itemBuilder: (context, index) {
                      final printer = _printers[index];
                      return ListTile(
                        leading: const Icon(Icons.print),
                        title: Text(printer.name.isEmpty ? 'Unknown Device' : printer.name),
                        subtitle: Text(printer.macAdress),
                        trailing: _isConnecting
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Connect'),
                        onTap: _isConnecting ? null : () => _connect(printer.macAdress),
                      );
                    },
                  ),
      ),
      actions: [
        TextButton(
          onPressed: _isConnecting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
