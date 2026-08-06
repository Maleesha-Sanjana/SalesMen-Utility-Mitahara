import 'package:flutter/material.dart';

import '../adminProfile.dart';

class SuperAdminProfilePage extends StatelessWidget {
  const SuperAdminProfilePage({super.key, this.appBarLeading});

  final Widget? appBarLeading;

  @override
  Widget build(BuildContext context) {
    return AdminProfilePage(appBarLeading: appBarLeading);
  }
}
