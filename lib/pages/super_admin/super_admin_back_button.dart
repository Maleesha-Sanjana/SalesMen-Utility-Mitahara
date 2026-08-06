import 'package:flutter/material.dart';

Widget superAdminBackButton(BuildContext context) {
  return IconButton(
    icon: const Icon(Icons.arrow_back),
    color: Theme.of(context).colorScheme.onSurface,
    tooltip: 'Back to Super Admin',
    onPressed: () => Navigator.of(context).pop(),
  );
}
