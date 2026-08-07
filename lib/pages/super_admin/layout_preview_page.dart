import 'package:flutter/material.dart';
import 'pdf_preview_page.dart';
import 'receipt_preview_page.dart';

class LayoutPreviewPage extends StatelessWidget {
  final Widget? appBarLeading;
  const LayoutPreviewPage({super.key, this.appBarLeading});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: appBarLeading,
        title: const Text('Layout Preview'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Card(
            elevation: 2,
            margin: const EdgeInsets.only(bottom: 16),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              leading: const CircleAvatar(
                backgroundColor: Color(0xFFE5E7EB),
                child: Icon(Icons.picture_as_pdf_rounded, color: Color(0xFFEF4444)),
              ),
              title: const Text('PDF View', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Preview how invoices look in A4 PDF format'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PdfPreviewPage()),
                );
              },
            ),
          ),
          Card(
            elevation: 2,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              leading: const CircleAvatar(
                backgroundColor: Color(0xFFE5E7EB),
                child: Icon(Icons.receipt_long_rounded, color: Color(0xFF3B82F6)),
              ),
              title: const Text('Receipt View', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Preview how invoices look in Thermal Receipt format'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ReceiptPreviewPage()),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
