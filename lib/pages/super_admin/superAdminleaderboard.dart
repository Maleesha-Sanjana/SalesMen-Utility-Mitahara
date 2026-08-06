import 'package:flutter/material.dart';

import '../leaderboard_page.dart';
import 'super_admin_back_button.dart';

class SuperAdminLeaderboardPage extends StatelessWidget {
  const SuperAdminLeaderboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return LeaderboardPage(appBarLeading: superAdminBackButton(context));
  }
}
