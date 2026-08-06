import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_service.dart';

class SalesmanProfilePage extends StatefulWidget {
  const SalesmanProfilePage({
    super.key,
    required this.salesmanCode,
    this.appBarLeading,
  });

  final String salesmanCode;
  final Widget? appBarLeading;

  @override
  State<SalesmanProfilePage> createState() => _SalesmanProfilePageState();
}

class _SalesmanProfilePageState extends State<SalesmanProfilePage> {
  final ImagePicker _imagePicker = ImagePicker();

  Map<String, dynamic>? _profile;
  String? _imageData;
  Uint8List? _previewBytes;
  bool _loading = true;
  bool _loadingImage = false;
  bool _uploadingImage = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await ApiService.getSalesmanProfile(widget.salesmanCode);
      final salesman = Map<String, dynamic>.from(
        response['salesman'] as Map? ?? {},
      );

      if (!mounted) return;
      setState(() {
        _profile = salesman;
        _loading = false;
      });

      await _loadImage(forceRefresh: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadImage({bool forceRefresh = false}) async {
    final code = widget.salesmanCode.trim();
    if (code.isEmpty) return;

    if (!forceRefresh && ApiService.hasCachedSalesmanImage(code)) {
      if (mounted) {
        setState(() => _imageData = ApiService.getCachedSalesmanImage(code));
      }
      return;
    }

    if (forceRefresh) {
      ApiService.clearSalesmanImageCache(code);
    }

    if (mounted) setState(() => _loadingImage = true);

    try {
      final image = await ApiService.fetchSalesmanImage(code);
      if (!mounted) return;
      setState(() {
        _imageData = image;
        _loadingImage = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingImage = false);
    }
  }

  Future<void> _showPhotoOptions() async {
    final canUpload = _profile?['hasProfileImage'] != false;
    if (!canUpload) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Photo upload is not available. Ask admin to add salesmanImg column.',
          ),
        ),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_rounded),
                title: const Text('Take Photo'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_rounded),
                title: const Text('Choose from Gallery'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      if (!mounted) return;

      setState(() {
        _previewBytes = bytes;
        _uploadingImage = true;
      });

      await ApiService.uploadSalesmanImage(widget.salesmanCode, bytes);

      if (!mounted) return;
      setState(() {
        _imageData = base64Encode(bytes);
        _uploadingImage = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile photo updated')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploadingImage = false;
        _previewBytes = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not update photo: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        automaticallyImplyLeading: widget.appBarLeading == null,
        title: const Text('My Profile'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      size: 48,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Could not load profile',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _loadProfile,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadProfile,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                child: _buildProfileContent(theme, _profile ?? {}),
              ),
            ),
    );
  }

  Widget _buildProfileContent(ThemeData theme, Map<String, dynamic> profile) {
    final name = _text(profile['SalesmanName']) ?? widget.salesmanCode;
    final code = _text(profile['SalesmanCode']) ?? widget.salesmanCode;
    final title = _text(profile['SalesmanTitle']) ?? 'Salesman';
    final accessLevel = _accessLevel(profile);
    final status = _status(profile);
    final canUploadPhoto = profile['hasProfileImage'] != false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: theme.colorScheme.outline.withValues(alpha: 0.2),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
            child: Column(
              children: [
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    _buildAvatar(theme, name, size: 96),
                    Material(
                      color: theme.colorScheme.primary,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _uploadingImage ? null : _showPhotoOptions,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: _uploadingImage
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: theme.colorScheme.onPrimary,
                                  ),
                                )
                              : Icon(
                                  Icons.camera_alt_rounded,
                                  size: 18,
                                  color: theme.colorScheme.onPrimary,
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _uploadingImage ? null : _showPhotoOptions,
                  icon: const Icon(Icons.add_a_photo_rounded, size: 18),
                  label: const Text('Change Profile Photo'),
                ),
                if (!canUploadPhoto)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Photo upload requires salesmanImg column in database',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  name,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  code,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
                if (accessLevel != null || status != null) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      if (accessLevel != null)
                        _chip(theme, accessLevel, theme.colorScheme.primary),
                      if (status != null)
                        _chip(
                          theme,
                          status,
                          status == 'Active'
                              ? const Color(0xFF10B981)
                              : theme.colorScheme.error,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        ..._buildSections(theme, profile),
      ],
    );
  }

  List<Widget> _buildSections(ThemeData theme, Map<String, dynamic> profile) {
    final sections =
        <
          ({
            String title,
            List<({String label, String? value})> rows,
          })
        >[
          (
            title: 'Contact',
            rows: [
              (label: 'Mobile', value: _text(profile['Mobile'])),
              (label: 'Telephone', value: _text(profile['Tno'])),
              (label: 'Fax', value: _text(profile['Fax'])),
              (label: 'Email', value: _text(profile['Email'])),
              (label: 'Website', value: _text(profile['WebSite'])),
            ],
          ),
          (
            title: 'Address',
            rows: [
              (label: 'Address 1', value: _text(profile['Address1'])),
              (label: 'Address 2', value: _text(profile['Address2'])),
              (label: 'Address 3', value: _text(profile['Address3'])),
              (label: 'Area Code', value: _text(profile['AreaCode'])),
              (label: 'Territory Code', value: _text(profile['TerritoryCode'])),
              (label: 'Root Code', value: _text(profile['RootCode'])),
            ],
          ),
          (
            title: 'Branch & Company',
            rows: [
              (label: 'Branch Code', value: _text(profile['Location'])),
              (label: 'Branch Name', value: _text(profile['LocationDescription'])),
              (label: 'Company', value: _text(profile['CompanyCode'])),
              (label: 'Cost Center', value: _text(profile['CostCenter'])),
            ],
          ),
          (
            title: 'Sales Details',
            rows: [
              (label: 'Salesman Code', value: _text(profile['SalesmanCode'])),
              (label: 'Salesman ID', value: _text(profile['SalesmanId'])),
              (label: 'Type', value: _text(profile['SalesmanType'])),
              (label: 'Salesman Group', value: _text(profile['SalesmanGroup'])),
              (label: 'Commission Policy', value: _text(profile['CommissionPolicy'])),
              (label: 'Discount Level', value: _text(profile['DiscountLevel'])),
            ],
          ),
          (
            title: 'Credit',
            rows: [
              (label: 'Credit Limit', value: _formatNumber(profile['CreditLimit'])),
              (
                label: 'Temporary Credit',
                value: _formatNumber(profile['TemporaryCredit']),
              ),
              (label: 'Credit Period', value: _formatNumber(profile['CreditPeriod'])),
              (label: 'Bank Account', value: _text(profile['BankAccount'])),
            ],
          ),
          (
            title: 'Record Info',
            rows: [
              (label: 'Created Date', value: _formatDate(profile['Created_Date'])),
              (label: 'Created User', value: _text(profile['Created_User'])),
              (label: 'Edited Date', value: _formatDate(profile['Edited_Date'])),
              (label: 'Edited User', value: _text(profile['Edited_User'])),
            ],
          ),
        ];

    return sections
        .map((section) {
          final visibleRows = section.rows
              .where((row) {
                final value = row.value;
                return value != null && value.trim().isNotEmpty;
              })
              .map((row) => (label: row.label, value: row.value!))
              .toList();
          if (visibleRows.isEmpty) return null;
          return _sectionCard(theme, section.title, visibleRows);
        })
        .whereType<Widget>()
        .toList();
  }

  Widget _sectionCard(
    ThemeData theme,
    String title,
    List<({String label, String value})> rows,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 10),
              ...rows.map((row) => _detailTile(theme, row.label, row.value)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(ThemeData theme, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _detailTile(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(ThemeData theme, String name, {required double size}) {
    final bytes = _previewBytes ?? _decodeBytes(_imageData);
    final radius = size / 2;

    return CircleAvatar(
      radius: radius,
      backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
      child: _loadingImage && bytes == null
          ? SizedBox(
              width: size * 0.35,
              height: size * 0.35,
              child: const CircularProgressIndicator(strokeWidth: 2),
            )
          : bytes != null
          ? ClipOval(
              child: Image.memory(
                bytes,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    _initialsAvatar(name, theme, size),
              ),
            )
          : _initialsAvatar(name, theme, size),
    );
  }

  Widget _initialsAvatar(String name, ThemeData theme, double size) {
    final initials = name.trim().isNotEmpty
        ? name.trim().split(RegExp(r'\s+')).take(2).map((p) => p[0]).join()
        : '?';

    return Text(
      initials.toUpperCase(),
      style: theme.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.primary,
        fontSize: size * 0.35,
      ),
    );
  }

  String? _text(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty || text.toUpperCase() == 'NULL') return null;
    return text;
  }

  String? _formatNumber(dynamic value) {
    final text = _text(value);
    if (text == null) return null;
    final number = num.tryParse(text);
    return number?.toString() ?? text;
  }

  String? _formatDate(dynamic value) {
    final text = _text(value);
    if (text == null) return null;
    final date = DateTime.tryParse(text);
    if (date == null) return text;
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String? _accessLevel(Map<String, dynamic> profile) {
    final isSuper = profile['isSuper'] == true || profile['isSuper'] == 1;
    final isAdmin = profile['isAdmin'] == true || profile['isAdmin'] == 1;
    if (isSuper) return 'Super Admin';
    if (isAdmin) return 'Admin';
    return 'Salesman';
  }

  String? _status(Map<String, dynamic> profile) {
    final blackListed = profile['BlackListed'];
    final suspend = profile['Suspend'];
    if (blackListed == 1) return 'Blacklisted';
    if (suspend == 1) return 'Suspended';
    return 'Active';
  }

  Uint8List? _decodeBytes(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    try {
      return base64Decode(value.trim());
    } catch (_) {
      return null;
    }
  }
}
