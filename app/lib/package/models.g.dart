// GENERATED CODE - DO NOT MODIFY BY HAND

part of pub_dartlang_org.appengine_repository.models;

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

LatestReleases _$LatestReleasesFromJson(Map<String, dynamic> json) =>
    LatestReleases(
      stable: Release.fromJson(json['stable'] as Map<String, dynamic>),
      prerelease: json['prerelease'] == null
          ? null
          : Release.fromJson(json['prerelease'] as Map<String, dynamic>),
      preview: json['preview'] == null
          ? null
          : Release.fromJson(json['preview'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$LatestReleasesToJson(LatestReleases instance) =>
    <String, dynamic>{
      'stable': instance.stable,
      'prerelease': instance.prerelease,
      'preview': instance.preview,
    };

Release _$ReleaseFromJson(Map<String, dynamic> json) => Release(
      version: json['version'] as String,
      published: DateTime.parse(json['published'] as String),
    );

Map<String, dynamic> _$ReleaseToJson(Release instance) => <String, dynamic>{
      'version': instance.version,
      'published': instance.published.toIso8601String(),
    };

PackageView _$PackageViewFromJson(Map<String, dynamic> json) => PackageView(
      name: json['name'] as String?,
      releases: json['releases'] == null
          ? null
          : LatestReleases.fromJson(json['releases'] as Map<String, dynamic>),
      ellipsizedDescription: json['ellipsizedDescription'] as String?,
      created: json['created'] == null
          ? null
          : DateTime.parse(json['created'] as String),
      flags:
          (json['flags'] as List<dynamic>?)?.map((e) => e as String).toList(),
      publisherId: json['publisherId'] as String?,
      isPending: json['isPending'] as bool?,
      likes: json['likes'] as int?,
      grantedPubPoints: json['grantedPubPoints'] as int?,
      maxPubPoints: json['maxPubPoints'] as int?,
      popularity: json['popularity'] as int?,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList(),
      spdxIdentifiers: (json['spdxIdentifiers'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      apiPages: (json['apiPages'] as List<dynamic>?)
          ?.map((e) => ApiPageRef.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$PackageViewToJson(PackageView instance) {
  final val = <String, dynamic>{};

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('name', instance.name);
  writeNotNull('releases', instance.releases);
  writeNotNull('ellipsizedDescription', instance.ellipsizedDescription);
  writeNotNull('created', instance.created?.toIso8601String());
  writeNotNull('flags', instance.flags);
  writeNotNull('publisherId', instance.publisherId);
  val['isPending'] = instance.isPending;
  writeNotNull('likes', instance.likes);
  writeNotNull('grantedPubPoints', instance.grantedPubPoints);
  writeNotNull('maxPubPoints', instance.maxPubPoints);
  writeNotNull('popularity', instance.popularity);
  val['tags'] = instance.tags;
  writeNotNull('spdxIdentifiers', instance.spdxIdentifiers);
  writeNotNull('apiPages', instance.apiPages);
  return val;
}
