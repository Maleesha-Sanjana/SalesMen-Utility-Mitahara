class Customer {
  final String code;
  final String name;
  final String? outletId;
  final String? address;
  final String? phone;
  final String? priceTier; // e.g., RETAIL, WHOLESALE
  final double creditLimit;
  final double currentOutstanding;

  const Customer({
    required this.code,
    required this.name,
    this.outletId,
    this.address,
    this.phone,
    this.priceTier,
    this.creditLimit = 0,
    this.currentOutstanding = 0,
  });

  factory Customer.fromJson(Map<String, dynamic> json) {
    return Customer(
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      outletId: json['outletId']?.toString(),
      address: json['address']?.toString(),
      phone: json['phone']?.toString(),
      priceTier: json['priceTier']?.toString(),
      creditLimit: double.tryParse(json['creditLimit']?.toString() ?? '0') ?? 0,
      currentOutstanding: double.tryParse(json['currentOutstanding']?.toString() ?? '0') ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'outletId': outletId,
    'address': address,
    'phone': phone,
    'priceTier': priceTier,
    'creditLimit': creditLimit,
    'currentOutstanding': currentOutstanding,
  };
}
