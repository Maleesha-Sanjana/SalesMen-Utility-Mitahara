# Sales Man Utility App 🚀

**Sales Man Utility** is a comprehensive Flutter-based mobile application designed for **Jazz Business Solutions (Pvt.) Ltd.** to streamline field sales operations, inventory management, and location tracking for sales teams and administrators.

## 📱 Overview

The application empowers sales representatives to efficiently take customer orders, manage stock, generate invoices, and log customer locations directly from their mobile devices. Simultaneously, it provides administrators with powerful tools for real-time tracking, user management, and performance monitoring.

## ✨ Key Features

### 🛒 Sales & Order Management
- **Invoicing & Quotations:** Create, manage, and generate PDF invoices and quotations on the go.
- **Sales Orders & Returns:** Seamlessly capture new sales orders and process sales return entries.
- **Receipts:** Digital receipt generation and printing capabilities.

### 📍 Location & Tracking
- **Live Device Tracking:** Real-time location tracking of sales personnel via background services.
- **Customer Locations:** Tag and manage physical locations of customers for optimized routing.
- **Interactive Maps:** Visual representation of salesman locations and customer pins using `flutter_map`.

### 📦 Inventory & Stock
- **Stock Tracking:** View location-wise stock and individual "My Stock" levels.
- **Stock Reports:** Generate and analyze stock availability and movement.

### 👥 User Roles & Management
- **Hierarchical Access:** Distinct dashboards and permissions for **Super Admins**, **Admins**, and **Normal Users (Salesmen)**.
- **User Management:** Admins can manage team members, view current sales, and track team performance.
- **Leaderboard:** Gamified performance tracking to motivate sales teams.

## 🛠️ Technology Stack

- **Framework:** [Flutter](https://flutter.dev/) (Dart)
- **State Management:** `provider`
- **Networking:** `http` for API communications
- **Local Storage:** `shared_preferences`
- **Location Services:** `geolocator`, `latlong2`, `flutter_map`
- **Background Processes:** `flutter_background_service`, `flutter_local_notifications`
- **PDF & Printing:** `pdf`, `printing`
- **Permissions:** `permission_handler`

## 🚀 Getting Started

### Prerequisites
- Flutter SDK (`^3.9.2` or compatible version)
- Dart SDK
- Android Studio / Xcode for platform-specific building

### Installation

1. **Clone the repository** (if applicable):
   ```bash
   git clone <repository-url>
   cd "Sales Man Utility"
   ```

2. **Install Dependencies:**
   ```bash
   flutter pub get
   ```

3. **Run the App:**
   ```bash
   flutter run
   ```

## 🏗️ Project Structure

- `lib/models/` - Data models and entities.
- `lib/pages/` - UI screens categorized by roles (Admin, Super Admin, Salesman).
- `lib/providers/` - State management logic.
- `lib/services/` - API integration and background service logic.
- `lib/utils/` - Helper functions and constants.
- `lib/widgets/` - Reusable UI components.

## 🔐 Permissions Required
To function correctly, the app requests the following device permissions:
- **Location:** (Foreground and Background) For live tracking and tagging customer locations.
- **Camera/Storage:** For capturing images (e.g., receipts or shop fronts).
- **Notifications:** For alerting users regarding background tasks and important updates.

## 📄 License
*Proprietary Software.* Developed for Jazz Business Solutions (Pvt.) Ltd. Unauthorized copying, distribution, or modification is prohibited.