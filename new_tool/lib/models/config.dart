class AppStoreConnectCreds {
  final String keyId;
  final String issuerId;

  AppStoreConnectCreds({required this.keyId, required this.issuerId});

  factory AppStoreConnectCreds.fromJson(Map<String, dynamic> j) =>
      AppStoreConnectCreds(
        keyId: j['key_id'] as String,
        issuerId: j['issuer_id'] as String,
      );
}

class AppMetadata {
  final String appId;
  final String packageId;
  final String? email;
  final String? name;
  final String? releaseNotes;
  final String? supportUrl;
  final String? privacyUrl;
  final String? primaryCategory;
  final String updateVersion;
  final String? marketingUrl;
  final String? copyright;

  AppMetadata({
    required this.appId,
    required this.packageId,
    this.email,
    this.name,
    this.releaseNotes,
    this.supportUrl,
    this.privacyUrl,
    this.primaryCategory,
    required this.updateVersion,
    this.marketingUrl,
    this.copyright,
  });

  factory AppMetadata.fromJson(Map<String, dynamic> j) => AppMetadata(
        appId: (j['app_id'] ?? '').toString(),
        packageId: (j['package_id'] ?? '').toString(),
        email: j['email'] as String?,
        name: j['name'] as String?,
        releaseNotes: j['release_notes'] as String?,
        supportUrl: j['support_url'] as String?,
        privacyUrl: j['privacy_url'] as String?,
        primaryCategory: j['primary_category'] as String?,
        updateVersion: (j['update_version'] ?? '').toString(),
        marketingUrl: j['marketing_url'] as String?,
        copyright: j['copyright'] as String?,
      );
}

class IapLocalization {
  final String locale;
  final String name;
  final String description;

  IapLocalization({required this.locale, required this.name, required this.description});

  factory IapLocalization.fromJson(Map<String, dynamic> j) => IapLocalization(
        locale: j['locale'] as String,
        name: (j['name'] ?? '') as String,
        description: (j['description'] ?? '') as String,
      );
}

class IapPricing {
  final String territory;
  final String pricePoint;

  IapPricing({required this.territory, required this.pricePoint});

  factory IapPricing.fromJson(Map<String, dynamic> j) => IapPricing(
        territory: (j['territory'] ?? '') as String,
        pricePoint: (j['price_point'] ?? '').toString(),
      );
}

class IapMetadata {
  final String productId;
  final String referenceName;
  final String purchaseType;
  final bool familySharable;
  final String reviewNotes;
  final IapPricing? pricing;
  final List<IapLocalization> localizations;

  IapMetadata({
    required this.productId,
    required this.referenceName,
    required this.purchaseType,
    required this.familySharable,
    required this.reviewNotes,
    required this.pricing,
    required this.localizations,
  });

  factory IapMetadata.fromJson(Map<String, dynamic> j) => IapMetadata(
        productId: j['product_id'] as String,
        referenceName: (j['reference_name'] ?? '') as String,
        purchaseType: (j['purchase_type'] ?? 'NON_CONSUMABLE') as String,
        familySharable: (j['family_sharable'] ?? false) as bool,
        reviewNotes: (j['review_notes'] ?? '') as String,
        pricing: j['pricing'] is Map<String, dynamic>
            ? IapPricing.fromJson(j['pricing'] as Map<String, dynamic>)
            : null,
        localizations: ((j['localizations'] as List?) ?? const [])
            .map((e) => IapLocalization.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class InAppConfig {
  final List<IapMetadata> iapMetadata;
  final bool availableInAllTerritories;
  final List<String> territories;
  final String iapTerritoryId;
  final String reviewImagePath;

  InAppConfig({
    required this.iapMetadata,
    required this.availableInAllTerritories,
    required this.territories,
    required this.iapTerritoryId,
    required this.reviewImagePath,
  });

  factory InAppConfig.fromJson(Map<String, dynamic> j) {
    final availability = (j['availability'] as Map<String, dynamic>?) ?? {};
    return InAppConfig(
      iapMetadata: ((j['iap_metadata'] as List?) ?? const [])
          .map((e) => IapMetadata.fromJson(e as Map<String, dynamic>))
          .toList(),
      availableInAllTerritories:
          (availability['available_in_all_territories'] ?? true) as bool,
      territories: ((availability['territories'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      iapTerritoryId: (j['iap_territory_id'] ?? 'USA') as String,
      reviewImagePath: (j['review_image_path'] ?? '') as String,
    );
  }
}

class UploadConfig {
  final AppStoreConnectCreds creds;
  final AppMetadata metadata;
  final String defaultLanguage;
  final List<String> localizations;
  final Map<String, String> specificNameLocales;
  final InAppConfig? inApp;

  UploadConfig({
    required this.creds,
    required this.metadata,
    required this.defaultLanguage,
    required this.localizations,
    required this.specificNameLocales,
    required this.inApp,
  });

  factory UploadConfig.fromJson(Map<String, dynamic> j) => UploadConfig(
        creds: AppStoreConnectCreds.fromJson(
            j['app_store_connect'] as Map<String, dynamic>),
        metadata: AppMetadata.fromJson(j['metadata'] as Map<String, dynamic>),
        defaultLanguage: (j['default_language'] ?? 'en-US') as String,
        localizations: ((j['localizations'] as List?) ?? const ['en-US'])
            .map((e) => e.toString())
            .toList(),
        specificNameLocales:
            ((j['specific_name_locales'] as Map?) ?? const {}).map(
                (k, v) => MapEntry(k.toString(), v.toString())),
        inApp: j['inapp'] is Map<String, dynamic>
            ? InAppConfig.fromJson(j['inapp'] as Map<String, dynamic>)
            : null,
      );
}
