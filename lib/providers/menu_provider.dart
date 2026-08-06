import 'package:flutter/foundation.dart';

class MenuProvider extends ChangeNotifier {
  bool _loading = false;
  String _searchQuery = '';

  bool get loading => _loading;
  String get searchQuery => _searchQuery;

  MenuProvider();

  Future<void> loadMenuData() async {
    _loading = true;
    notifyListeners();

    try {
      // Data loading is now handled by DatabaseDataProvider
      // This method is kept for compatibility
    } catch (e) {
      debugPrint('Error loading menu data: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void clearSelection() {
    _searchQuery = '';
    notifyListeners();
  }
}
