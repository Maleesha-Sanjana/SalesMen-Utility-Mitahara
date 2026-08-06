import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/product_image_cache_service.dart';

class ProductImageThumbnail extends StatefulWidget {
  const ProductImageThumbnail({
    super.key,
    this.image,
    this.productCode,
    this.size = 56,
    this.expand = false,
  });

  final dynamic image;
  final String? productCode;
  final double size;
  final bool expand;

  @override
  State<ProductImageThumbnail> createState() => _ProductImageThumbnailState();
}

class _ProductImageThumbnailState extends State<ProductImageThumbnail> {
  dynamic _resolvedImage;
  File? _localFile;
  String? _networkUrl;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _resolvedImage = widget.image;
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant ProductImageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image ||
        widget.productCode != oldWidget.productCode) {
      _resolvedImage = widget.image;
      _localFile = null;
      _networkUrl = null;
      _resolveImage();
    }
  }

  String? _fileUrlFor(String? productCode) {
    final code = productCode?.trim();
    if (code == null || code.isEmpty) return null;
    return ApiService.productImageFileUrl(code);
  }

  Future<void> _resolveImage() async {
    final code = widget.productCode?.trim();

    // 1) Local disk cache (offline / fast)
    if (code != null && code.isNotEmpty) {
      final local = await ProductImageCacheService.localImageFile(code);
      if (!mounted) return;
      if (local != null) {
        setState(() {
          _localFile = local;
          _networkUrl = null;
          _loading = false;
        });
        return;
      }
    }

    // 2) Embedded / already-fetched bytes
    if (_decodeBytes(_resolvedImage) != null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    // 3) Network binary URL
    final fileUrl = _fileUrlFor(code);
    if (fileUrl != null) {
      if (mounted) {
        setState(() {
          _networkUrl = fileUrl;
          _loading = false;
        });
      }
      return;
    }

    if (code == null || code.isEmpty) return;

    final cached = ApiService.getCachedProductImage(code);
    if (cached != null && _decodeBytes(cached) != null) {
      if (mounted) {
        setState(() => _resolvedImage = cached);
      }
      return;
    }

    if (_loading) return;
    if (mounted) setState(() => _loading = true);

    try {
      final image = await ApiService.fetchProductImage(code);
      if (!mounted) return;
      setState(() {
        _resolvedImage = image;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // IgnorePointer so parent InkWell (tap-to-add) always receives taps.
    final child = IgnorePointer(
      child: _loading
          ? const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : _buildImage(),
    );

    if (widget.expand) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: SizedBox.expand(child: child),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: widget.size,
        height: widget.size,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: child,
      ),
    );
  }

  Widget _buildImage() {
    if (_localFile != null) {
      return Image.file(
        _localFile!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _fallbackImage(),
      );
    }

    if (_networkUrl != null) {
      return Image.network(
        _networkUrl!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) {
          final bytes = _decodeBytes(_resolvedImage);
          if (bytes != null) {
            return Image.memory(bytes, fit: BoxFit.cover);
          }
          return _fallbackImage();
        },
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        },
      );
    }

    final imageText = _resolvedImage?.toString().trim() ?? '';
    final bytes = _decodeBytes(_resolvedImage);

    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _fallbackImage(),
      );
    }

    if (imageText.startsWith('http://') || imageText.startsWith('https://')) {
      return Image.network(
        imageText,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallbackImage(),
      );
    }

    return _fallbackImage();
  }

  Widget _fallbackImage() {
    return Image.asset(
      'assets/jazz.png',
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const Icon(Icons.inventory_2_rounded),
    );
  }

  Uint8List? _decodeBytes(dynamic value) {
    if (value == null) return null;

    if (value is Uint8List) return value.isEmpty ? null : value;

    if (value is List) {
      if (value.isEmpty) return null;
      return Uint8List.fromList(value.cast<int>());
    }

    if (value is Map && value['data'] is List) {
      final list = value['data'] as List;
      if (list.isEmpty) return null;
      return Uint8List.fromList(list.cast<int>());
    }

    if (value is! String) return null;

    var text = value.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('http://') || text.startsWith('https://')) return null;

    if (text.startsWith('data:image') && text.contains(',')) {
      text = text.split(',').last;
    }

    final hexBytes = _decodeHex(text);
    if (hexBytes != null) return hexBytes;

    try {
      final bytes = base64Decode(text);
      if (bytes.isEmpty) return null;
      if (!_looksLikeImageBytes(bytes)) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeImageBytes(Uint8List bytes) {
    if (bytes.length < 4) return false;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) return true;
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    return false;
  }

  Uint8List? _decodeHex(String text) {
    var hex = text.trim();
    final hadPrefix = hex.startsWith('0x') || hex.startsWith('0X');
    if (hadPrefix) {
      hex = hex.substring(2);
    }
    if (hex.isEmpty || hex.length.isOdd) return null;
    if (!RegExp(r'^[0-9A-Fa-f]+$').hasMatch(hex)) return null;

    final upper = hex.toUpperCase();
    final looksLikeImage = upper.startsWith('FFD8') ||
        upper.startsWith('89504E47') ||
        upper.startsWith('474946') ||
        upper.startsWith('424D') ||
        hadPrefix;

    if (!looksLikeImage) return null;

    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      out[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return _looksLikeImageBytes(out) ? out : null;
  }
}
