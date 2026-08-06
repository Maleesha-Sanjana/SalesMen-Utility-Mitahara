import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'pages/login_page.dart';
import 'pages/invoice_page.dart';
import 'pages/home_page.dart';
import 'pages/super_admin/super_admin_home_page.dart';
import 'pages/super_admin/superAdminsalesorder.dart';
import 'pages/super_admin/superAdmininvoice.dart';
import 'pages/super_admin/superAdminquotation.dart';
import 'pages/super_admin/superAdmincrn.dart';
import 'pages/super_admin/superAdminreceipt.dart';
import 'pages/super_admin/superAdmincustomercreate.dart';
import 'pages/super_admin/superAdmincustomerlocations.dart';
import 'pages/super_admin/superAdminmylocationhistory.dart';
import 'pages/super_admin/superAdminleaderboard.dart';
import 'pages/super_admin/superAdminstockreports.dart';
import 'pages/super_admin/superAdminsalesmanlocation.dart';
import 'pages/super_admin/superAdminusercreation.dart';
import 'pages/super_admin/superAdmincurrentsale.dart';
import 'pages/super_admin/superAdminprofile.dart';
import 'pages/super_admin/superAdminsaleshistory.dart';
import 'pages/super_admin/superAdmininvoicereport.dart';
import 'pages/super_admin/superAdminsalesorderreport.dart';
import 'pages/super_admin/superAdminquotationreport.dart';
import 'pages/super_admin/superAdmincrnreport.dart';
import 'pages/super_admin/superAdminlocationtracking.dart';
import 'pages/super_admin/superAdmindevicetracking.dart';
import 'pages/admin_home_page.dart';
import 'pages/normal_user_home_page.dart';
import 'pages/customer_creation_page.dart';
import 'pages/receipt_page.dart';
import 'pages/crn.dart';
import 'pages/my_sales_and_history_page.dart';
import 'pages/sales_order_page.dart';
import 'pages/quotation_page.dart';
import 'pages/stock_reports_page.dart';
import 'pages/my_stock_page.dart';
import 'pages/admin/assign_customers_page.dart';
import 'pages/location_wise_stock_page.dart';
import 'pages/my_history/my_history_invoice_page.dart';
import 'pages/my_history/my_history_sales_order_page.dart';
import 'pages/super_admin/superAdminUserRights.dart';
import 'pages/my_history/my_history_quotation_page.dart';
import 'pages/my_history/my_history_crn_page.dart';
import 'pages/my_history/my_history_location_page.dart';
import 'pages/adminProfile.dart';
import 'pages/SalesAndhistory.dart';
import 'pages/admin_history/admin_history_invoice_page.dart';
import 'pages/admin_history/admin_history_sales_order_page.dart';
import 'pages/admin_history/admin_history_quotation_page.dart';
import 'pages/admin_history/admin_history_crn_page.dart';
import 'pages/admin_user_management_page.dart';
import 'pages/admin_location_tracking_page.dart';
import 'pages/admin_device_tracking_page.dart';
import 'pages/admin_current_sale_page.dart';
import 'pages/leaderboard_page.dart';
import 'pages/salesmanWiseLocation.dart';
import 'providers/auth_provider.dart';
import 'providers/menu_provider.dart';
import 'providers/cart_provider.dart';
import 'providers/database_data_provider.dart';
import 'services/background_location_service.dart';
import 'services/pdf_fonts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Preload PDF fonts in background while the app starts (avoids delay on Generate PDF).
  PdfFonts.preload();

  // Initialize background location service with comprehensive error handling
  try {
    await BackgroundLocationService.initializeService();
    print('✅ Background location service initialized');
  } catch (e) {
    print('⚠️ Background location service initialization failed: $e');
    // Continue app startup even if background service fails
    // This is not critical for app functionality
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => MenuProvider()),
        ChangeNotifierProvider(create: (_) => CartProvider()),
        ChangeNotifierProvider(create: (_) => DatabaseDataProvider()),
      ],

      child: MaterialApp(
        title: 'Distribution App',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme:
              ColorScheme.fromSeed(
                seedColor: const Color(0xFF598DC9), // Blue
                brightness: Brightness.light,
              ).copyWith(
                primary: const Color(0xFF598DC9), // Blue
                secondary: const Color(0xFF4A7FC7), // Darker blue
                tertiary: const Color(0xFF06B6D4), // Cyan 500
                surface: const Color(0xFFFAFAFA), // Gray 50
                surfaceContainerHighest: const Color(0xFFF8FAFC), // Slate 50
                onSurface: const Color(0xFF1E293B), // Slate 800 - Dark text
                onSurfaceVariant: const Color(
                  0xFF64748B,
                ), // Slate 500 - Medium text
                onPrimary: Colors.white, // White text on primary
                onSecondary: Colors.white, // White text on secondary
                outline: const Color(0xFFE2E8F0), // Slate 200
                outlineVariant: const Color(0xFFF1F5F9), // Slate 100
                error: const Color(0xFFEF4444), // Red 500
                onError: Colors.white,
                errorContainer: const Color(0xFFFEF2F2), // Red 50
                onErrorContainer: const Color(0xFF991B1B), // Red 800
              ),
          textTheme: const TextTheme(
            displayLarge: TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.0,
              height: 1.1,
            ),
            displayMedium: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.75,
              height: 1.2,
            ),
            displaySmall: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              height: 1.3,
            ),
            headlineLarge: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.25,
              height: 1.3,
            ),
            headlineMedium: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
              height: 1.4,
            ),
            headlineSmall: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
              height: 1.4,
            ),
            titleLarge: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
              height: 1.4,
            ),
            titleMedium: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.15,
              height: 1.5,
            ),
            titleSmall: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.1,
              height: 1.4,
            ),
            bodyLarge: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.15,
              height: 1.5,
            ),
            bodyMedium: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.25,
              height: 1.5,
            ),
            bodySmall: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.4,
              height: 1.4,
            ),
            labelLarge: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.1,
              height: 1.4,
            ),
            labelMedium: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
              height: 1.3,
            ),
            labelSmall: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
              height: 1.3,
            ),
          ),
          cardTheme: CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            color: Colors.white,
            shadowColor: Colors.black.withOpacity(0.05),
            surfaceTintColor: Colors.transparent,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFF598DC9), width: 2),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFEF4444)),
            ),
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 18,
            ),
            labelStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Color(0xFF475569), // Darker for better visibility
            ),
            hintStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Color(0xFF64748B), // Medium gray for better visibility
            ),
          ),
          appBarTheme: const AppBarTheme(
            elevation: 0,
            centerTitle: false,
            titleTextStyle: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1E293B),
            ),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
          ),
          scaffoldBackgroundColor: const Color(0xFFFAFAFA),
        ),
        routes: {
          '/': (_) => const LandingPage(),
          '/invoices': (_) => const InvoiceSimplePage(),
          '/home': (_) => const HomePage(),
          '/super-admin-home': (_) => const SuperAdminHomePage(),
          '/admin-home': (_) => const AdminHomePage(),
          '/normal-user-home': (_) => const NormalUserHomePage(),
          '/customer-create': (_) => const CustomerCreationPage(),
          '/receipt': (_) => const ReceiptPage(),
          '/sales-return': (_) => const CrnPage(),
          '/my-sales': (_) => const MySalesAndHistoryPage(),
          '/my-history/invoices': (_) => const MyHistoryInvoicePage(),
          '/my-history/sales-orders': (_) => const MyHistorySalesOrderPage(),
          '/my-history/quotations': (_) => const MyHistoryQuotationPage(),
          '/my-history/crn': (_) => const MyHistoryCrnPage(),
          '/my-history/locations': (_) => const MyHistoryLocationPage(),
          '/sales-order': (_) => const SalesOrderPage(),
          '/quotation': (_) => const QuotationPage(),
          '/stock-reports': (_) => const StockReportsPage(),
          '/my-stock': (_) => const MyStockPage(),
          '/location-stock': (_) => const LocationWiseStockPage(),
          '/admin/users': (_) => const AdminUserManagementPage(),
          '/admin/profile': (_) => const AdminProfilePage(),
          '/super-admin/user-rights': (_) => const SuperAdminUseRightsPage(),
          '/admin/user-rights': (_) => const SuperAdminUseRightsPage(),
          '/admin/assign-customers': (_) => const AssignCustomersPage(),
          '/admin/location-tracking': (_) => const AdminLocationTrackingPage(),
          '/admin/device-tracking': (_) => const AdminDeviceTrackingPage(),
          '/admin/current-sale': (_) => const AdminCurrentSalePage(),
          '/admin/sales-and-history': (_) => const SalesAndhistoryPage(),
          '/admin/leaderboard': (_) => const LeaderboardPage(),
          '/admin/salesman-location-history': (_) =>
              const SalesmanWiseLocationPage(),
          '/admin-history/invoices': (_) => const AdminHistoryInvoicePage(),
          '/admin-history/sales-orders': (_) => const AdminHistorySalesOrderPage(),
          '/admin-history/quotations': (_) => const AdminHistoryQuotationPage(),
          '/admin-history/crn': (_) => const AdminHistoryCrnPage(),
          '/super-admin/ref/sales-order': (_) =>
              const SuperAdminSalesOrderPage(),
          '/super-admin/ref/invoice': (_) => const SuperAdminInvoicePage(),
          '/super-admin/ref/quotation': (_) => const SuperAdminQuotationPage(),
          '/super-admin/ref/crn': (_) => const SuperAdminCrnPage(),
          '/super-admin/ref/receipt': (_) => const SuperAdminReceiptPage(),
          '/super-admin/ref/customer-create': (_) =>
              const SuperAdminCustomerCreatePage(),
          '/super-admin/ref/customer-locations': (_) =>
              const SuperAdminCustomerLocationsPage(),
          '/super-admin/ref/history/location': (_) =>
              const SuperAdminMyLocationHistoryPage(),
          '/super-admin/ref/leaderboard': (_) =>
              const SuperAdminLeaderboardPage(),
          '/super-admin/ref/stock-reports': (_) =>
              const SuperAdminStockReportsPage(),
          '/super-admin/admin/salesman-location-history': (_) =>
              const SuperAdminSalesmanLocationPage(),
          '/super-admin/admin/users': (_) => const SuperAdminUserCreationPage(),
          '/super-admin/admin/current-sale': (_) =>
              const SuperAdminCurrentSalePage(),
          '/super-admin/profile': (_) => const SuperAdminProfilePage(),
          '/super-admin/admin/profile': (_) => const SuperAdminProfilePage(),
          '/super-admin/admin/sales-and-history': (_) =>
              const SuperAdminSalesHistoryPage(),
          '/super-admin/admin/invoice': (_) =>
              const SuperAdminInvoiceReportPage(),
          '/super-admin/admin/sales-order-history': (_) =>
              const SuperAdminSalesOrderReportPage(),
          '/super-admin/admin/quotation-history': (_) =>
              const SuperAdminQuotationReportPage(),
          '/super-admin/admin/crn-history': (_) =>
              const SuperAdminCrnReportPage(),
          '/super-admin/admin/location-tracking': (_) =>
              const SuperAdminLocationTrackingPage(),
          '/super-admin/admin/leaderboard': (_) =>
              const SuperAdminLeaderboardPage(),
          '/super-admin/device-tracking': (_) =>
              const SuperAdminDeviceTrackingPage(),
        },
      ),
    );
  }
}
