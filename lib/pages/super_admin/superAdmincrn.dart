import 'package:flutter/material.dart';

import '../crn.dart';
import 'super_admin_back_button.dart';

class SuperAdminCrnPage extends StatelessWidget {
  const SuperAdminCrnPage({super.key});

  @override
  Widget build(BuildContext context) {
    return CrnPage(appBarLeading: superAdminBackButton(context));
  }
}
