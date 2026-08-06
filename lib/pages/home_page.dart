import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    // Redirect to appropriate homepage based on user type
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (auth.isSuper) {
        Navigator.of(context).pushReplacementNamed('/super-admin-home');
      } else if (auth.isAdmin) {
        Navigator.of(context).pushReplacementNamed('/admin-home');
      } else {
        Navigator.of(context).pushReplacementNamed('/normal-user-home');
      }
    });

    // Show loading while redirecting
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
