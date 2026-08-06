import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'salesman_profile_page.dart';

class AdminProfilePage extends StatelessWidget {
  const AdminProfilePage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    if (auth.salesmanCode.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          leading: appBarLeading,
          automaticallyImplyLeading: appBarLeading == null,
          title: const Text('My Profile'),
        ),
        body: const Center(
          child: Text('Admin profile information is not available'),
        ),
      );
    }

    return SalesmanProfilePage(
      salesmanCode: auth.salesmanCode,
      appBarLeading: appBarLeading,
    );
  }
}
