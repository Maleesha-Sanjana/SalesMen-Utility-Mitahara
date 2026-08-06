class Salesman {
  final int idx;
  final String salesmanCode;
  final String? salesmanName;
  final String? salesmanTitle;
  final String? salesmanType;
  final String? salesmanId;
  final String? areaCode;
  final String? territoryCode;
  final String? rootCode;
  final String? address1;
  final String? address2;
  final String? address3;
  final String? tno;
  final String? mobile;
  final String? fax;
  final String? email;
  final String? bankAccount;
  final double? creditLimit;
  final double? temporaryCredit;
  final double? creditPeriod;
  final String? discountLevel;
  final int? blackListed;
  final int? suspend;
  final String? webSite;
  final String? location;
  final int? showLocation;
  final bool? update;
  final DateTime? createdDate;
  final String? createdUser;
  final DateTime? editedDate;
  final String? editedUser;
  final String? salesmanPassword;
  final String? locationDescription;
  final String? companyCode;
  final bool? isAdmin;
  final bool? isSuper;

  const Salesman({
    required this.idx,
    required this.salesmanCode,
    this.salesmanName,
    this.salesmanTitle,
    this.salesmanType,
    this.salesmanId,
    this.areaCode,
    this.territoryCode,
    this.rootCode,
    this.address1,
    this.address2,
    this.address3,
    this.tno,
    this.mobile,
    this.fax,
    this.email,
    this.bankAccount,
    this.creditLimit,
    this.temporaryCredit,
    this.creditPeriod,
    this.discountLevel,
    this.blackListed,
    this.suspend,
    this.webSite,
    this.location,
    this.showLocation,
    this.update,
    this.createdDate,
    this.createdUser,
    this.editedDate,
    this.editedUser,
    this.salesmanPassword,
    this.locationDescription,
    this.companyCode,
    this.isAdmin,
    this.isSuper,
  });

  factory Salesman.fromJson(Map<String, dynamic> json) {
    // Helper function to safely parse double values
    double? safeParseDouble(dynamic value) {
      if (value == null || value.toString() == 'NULL') return null;
      return double.tryParse(value.toString());
    }

    // Helper function to safely parse int values
    int? safeParseInt(dynamic value) {
      if (value == null || value.toString() == 'NULL') return null;
      return int.tryParse(value.toString());
    }

    // Helper function to safely parse DateTime values
    DateTime? safeParseDateTime(dynamic value) {
      if (value == null || value.toString() == 'NULL') return null;
      return DateTime.tryParse(value.toString());
    }

    return Salesman(
      idx: json['Idx'] ?? json['idx'] ?? 0,
      salesmanCode:
          json['SalesmanCode']?.toString() ??
          json['salesmanCode']?.toString() ??
          json['id']?.toString() ??
          '',
      salesmanName:
          json['SalesmanName']?.toString() ??
          json['salesmanName']?.toString() ??
          json['name']?.toString(),
      salesmanTitle: json['SalesmanTitle']?.toString(),
      salesmanType: json['SalesmanType']?.toString(),
      salesmanId: json['SalesmanId']?.toString(),
      areaCode: json['AreaCode']?.toString(),
      territoryCode: json['TerritoryCode']?.toString(),
      rootCode: json['RootCode']?.toString(),
      address1: json['Address1']?.toString(),
      address2: json['Address2']?.toString(),
      address3: json['Address3']?.toString(),
      tno: json['Tno']?.toString(),
      mobile: json['Mobile']?.toString(),
      fax: json['Fax']?.toString(),
      email: json['Email']?.toString(),
      bankAccount: json['BankAccount']?.toString(),
      creditLimit: safeParseDouble(json['CreditLimit']),
      temporaryCredit: safeParseDouble(json['TemporaryCredit']),
      creditPeriod: safeParseDouble(json['CreditPeriod']),
      discountLevel: json['DiscountLevel']?.toString(),
      blackListed: safeParseInt(json['BlackListed']),
      suspend: safeParseInt(json['Suspend']),
      webSite: json['WebSite']?.toString(),
      location: json['Location']?.toString(),
      showLocation: safeParseInt(json['ShowLocation']),
      update: json['Update']?.toString() == '1',
      createdDate: safeParseDateTime(json['Created_Date']),
      createdUser: json['Created_User']?.toString(),
      editedDate: safeParseDateTime(json['Edited_Date']),
      editedUser: json['Edited_User']?.toString(),
      salesmanPassword: json['salesman_password']?.toString(),
      locationDescription: json['LocationDescription']?.toString(),
      companyCode: json['CompanyCode']?.toString(),
      isAdmin: json['isAdmin'] == true || json['isAdmin'] == 1,
      isSuper: json['isSuper'] == true || json['isSuper'] == 1,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'Idx': idx,
      'SalesmanCode': salesmanCode,
      'SalesmanName': salesmanName,
      'SalesmanTitle': salesmanTitle,
      'SalesmanType': salesmanType,
      'SalesmanId': salesmanId,
      'AreaCode': areaCode,
      'TerritoryCode': territoryCode,
      'RootCode': rootCode,
      'Address1': address1,
      'Address2': address2,
      'Address3': address3,
      'Tno': tno,
      'Mobile': mobile,
      'Fax': fax,
      'Email': email,
      'BankAccount': bankAccount,
      'CreditLimit': creditLimit,
      'TemporaryCredit': temporaryCredit,
      'CreditPeriod': creditPeriod,
      'DiscountLevel': discountLevel,
      'BlackListed': blackListed,
      'Suspend': suspend,
      'WebSite': webSite,
      'Location': location,
      'ShowLocation': showLocation,
      'Update': update,
      'Created_Date': createdDate?.toIso8601String(),
      'Created_User': createdUser,
      'Edited_Date': editedDate?.toIso8601String(),
      'Edited_User': editedUser,
      'salesman_password': salesmanPassword,
      'LocationDescription': locationDescription,
      'CompanyCode': companyCode,
      'isAdmin': isAdmin,
      'isSuper': isSuper,
    };
  }

  // Helper method to check if salesman is active (not blacklisted or suspended)
  bool get isActive {
    return (blackListed == 0 || blackListed == null) &&
        (suspend == 0 || suspend == null);
  }

  // Helper method to get display name
  String get displayName {
    return salesmanName ?? salesmanCode;
  }

  // Helper method to get title
  String get title {
    return salesmanTitle ?? 'Salesman';
  }

  // Helper method to get company name (location description)
  String get companyName {
    return locationDescription ?? 'Company';
  }
}
