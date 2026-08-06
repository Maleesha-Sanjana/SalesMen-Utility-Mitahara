import 'package:flutter/material.dart';

import '../services/product_image_cache_service.dart';

/// AppBar action: download product images to local storage.
class ProductImageDownloadButton extends StatefulWidget {
  const ProductImageDownloadButton({super.key, this.accentColor});

  final Color? accentColor;

  @override
  State<ProductImageDownloadButton> createState() =>
      _ProductImageDownloadButtonState();
}

class _ProductImageDownloadButtonState
    extends State<ProductImageDownloadButton> {
  bool _busy = false;

  Future<void> _onPressed() async {
    if (_busy || ProductImageCacheService.isSyncing) return;

    setState(() => _busy = true);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return ValueListenableBuilder<ProductImageSyncProgress?>(
          valueListenable: ProductImageCacheService.progress,
          builder: (context, progress, _) {
            final fraction = progress?.fraction ?? 0;
            final message = progress?.message ?? 'Starting download…';
            final done = progress != null && !progress.isRunning;

            return AlertDialog(
              title: const Text('Product images'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(value: done ? 1 : fraction),
                  const SizedBox(height: 12),
                  Text(message),
                  if (progress != null && progress.total > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${progress.completed} / ${progress.total}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
              actions: [
                if (done)
                  FilledButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Close'),
                  ),
              ],
            );
          },
        );
      },
    );

    try {
      await ProductImageCacheService.syncAll(force: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image download failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.accentColor ?? Theme.of(context).colorScheme.primary;

    return IconButton(
      tooltip: 'Download product images',
      onPressed: _busy ? null : _onPressed,
      icon: _busy
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: color,
              ),
            )
          : Icon(Icons.cloud_download_rounded, color: color),
    );
  }
}
