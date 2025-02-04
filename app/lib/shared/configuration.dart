// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert' show json;
import 'dart:io';

import 'package:collection/collection.dart' show UnmodifiableSetView;
import 'package:gcloud/service_scope.dart' as ss;
import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:pub_dev/frontend/static_files.dart';
import 'package:pub_dev/shared/env_config.dart';
import 'package:yaml/yaml.dart';

part 'configuration.g.dart';

final _configurationKey = #_active_configuration;

/// Gets the active configuration.
Configuration get activeConfiguration {
  Configuration? config = ss.lookup(_configurationKey) as Configuration?;
  if (config == null) {
    config = Configuration.fromEnv();
    ss.register(_configurationKey, config);
  }
  return config;
}

/// Sets the active configuration.
void registerActiveConfiguration(Configuration configuration) {
  ss.register(_configurationKey, configuration);
}

/// Special value to indicate that the site is running in fake mode, and the
/// client side authentication should use the fake authentication tokens.
const _fakeSiteAudience = 'fake-site-audience';

/// Class describing the configuration of running the pub site.
///
/// The configuration define the location of the Datastore with the
/// package metadata and the Cloud Storage bucket for the actual package
/// tar files.
@sealed
@JsonSerializable(
  anyMap: true,
  explicitToJson: true,
  checked: true,
  disallowUnrecognizedKeys: true,
)
class Configuration {
  /// The name of the Cloud Storage bucket to use for storing the uploaded
  /// package archives.
  ///
  /// The bucket content policy should be private.
  final String? canonicalPackagesBucketName;

  /// The name of the Cloud Storage bucket to use for public package archive downloads.
  ///
  /// This is the bucket which users are redirected to when they want to download package tarballs.
  /// The bucket content policy should be public.
  final String? publicPackagesBucketName;

  /// The name of the Cloud Storage bucket to use for incoming package archives.
  ///
  /// When users are publishing packages using the `dart pub` client, they are given a signed-url
  /// which allows the client to upload a file. That signed-url points to an object in this bucket.
  /// Once the uploaded tarball have been verified, it can be copied to the canonical bucket.
  /// The bucket content policy should be public.
  final String? incomingPackagesBucketName;

  /// The name of the Cloud Storage bucket to use for uploaded package content.
  final String? packageBucketName;

  /// The name of the Cloud Storage bucket to use for uploaded images.
  final String? imageBucketName;

  /// The Cloud project Id. This is only required when using Apiary to access
  /// Datastore and/or Cloud Storage
  final String projectId;

  /// The scheme://host:port prefix for the search service.
  final String searchServicePrefix;

  /// The name of the Cloud Storage bucket to use for dartdoc generated output.
  final String? dartdocStorageBucketName;

  /// The name of the Cloud Storage bucket to use for popularity data dumps.
  final String? popularityDumpBucketName;

  /// The name of the Cloud Storage bucket to use for search snapshots.
  final String? searchSnapshotBucketName;

  // The scheme://host:port prefix for storage URLs.
  final String? storageBaseUrl;

  /// The OAuth audience (`client_id`) that the `pub` client uses.
  final String? pubClientAudience;

  /// The OAuth audience (`client_id`) that the pub site uses.
  final String? pubSiteAudience;

  /// The OAuth audience (`client_id`) that admin accounts use.
  final String? adminAudience;

  /// Email of the service account which has domain-wide delegation for the
  /// GSuite account used to send emails.
  ///
  /// The [gmailRelayServiceAccount] has the following requirements:
  ///
  ///  1. The _service account_ running the server (typically appengine), must
  ///     have the `roles/iam.serviceAccountTokenCreator` role on the
  ///     [gmailRelayServiceAccount], allowing the server to create tokens
  ///     impersonating [gmailRelayServiceAccount].
  ///  2. The [gmailRelayServiceAccount] must be visible for
  ///     _domain-wide delegation_ in the Google Cloud Console.
  ///  3. The [gmailRelayServiceAccount] must be granted the scope:
  ///     `https://mail.google.com/` on the GSuite used for sending emails.
  ///
  ///  For (2) and (3) see:
  ///  https://developers.google.com/identity/protocols/oauth2/service-account
  ///
  /// **Optional**, if omitted email sending is disabled.
  final String? gmailRelayServiceAccount;

  /// Email of the GSuite user account to impersonate when sending emails
  /// through the gmail SMTP relay.
  ///
  /// This must be the email for an account within the GSuite used for sending
  /// emails. It is important that the gmail SMTP relay is enabled for this
  /// GSuite, for configuration see:
  /// https://support.google.com/a/answer/176600?hl=en
  ///
  /// **Optional**, if omitted email sending is disabled.
  final String? gmailRelayImpersonatedGSuiteUser;

  /// The email of the service account which has access rights to sign upload
  /// requests. The current service must be able to impersonate this account.
  ///
  /// Authorization requires the following IAM permission on the package bucket:
  /// - iam.serviceAccounts.signBlob
  ///
  /// https://cloud.google.com/iam/docs/reference/credentials/rest/v1/projects.serviceAccounts/signBlob
  final String? uploadSignerServiceAccount;

  /// Whether indexing of the content by robots should be blocked.
  final bool blockRobots;

  /// The list of hostnames which are considered production hosts (e.g. which
  /// are not limited in the cache use).
  final List<String>? productionHosts;

  /// The base URI to use for API endpoints.
  /// Also used as PUB_HOSTED_URL in analyzer and dartdoc.
  final Uri? primaryApiUri;

  /// The base URI to use for HTML content.
  final Uri primarySiteUri;

  /// The identifier of admins.
  final List<AdminId>? admins;

  /// The local command-line tools.
  final ToolsConfiguration? tools;

  /// Load [Configuration] from YAML file at [path] substituting `{{ENV}}` for
  /// the value of environment variable `ENV`.
  factory Configuration.fromYamlFile(final String path) {
    final content = File(path)
        .readAsStringSync()
        .replaceAllMapped(RegExp(r'\{\{([A-Z]+[A-Z0-9_]*)\}\}'), (match) {
      final name = match.group(1);
      if (name != null &&
          Platform.environment.containsKey(name) &&
          Platform.environment[name]!.isNotEmpty) {
        return Platform.environment[name]!;
      }
      return match.group(0)!;
    });
    return Configuration.fromJson(
      json.decode(json.encode(loadYaml(content))) as Map<String, dynamic>,
    );
  }

  Configuration({
    required this.canonicalPackagesBucketName,
    required this.publicPackagesBucketName,
    required this.incomingPackagesBucketName,
    required this.projectId,
    required this.packageBucketName,
    required this.imageBucketName,
    required this.dartdocStorageBucketName,
    required this.popularityDumpBucketName,
    required this.searchSnapshotBucketName,
    required this.searchServicePrefix,
    required this.storageBaseUrl,
    required this.pubClientAudience,
    required this.pubSiteAudience,
    required this.adminAudience,
    required this.gmailRelayServiceAccount,
    required this.gmailRelayImpersonatedGSuiteUser,
    required this.uploadSignerServiceAccount,
    required this.blockRobots,
    required this.productionHosts,
    required this.primaryApiUri,
    required this.primarySiteUri,
    required this.admins,
    required this.tools,
  });

  /// Load configuration from `app/config/<projectId>.yaml` where `projectId`
  /// is the GCP Project ID (specified using `GOOGLE_CLOUD_PROJECT`).
  factory Configuration.fromEnv() {
    // The GOOGLE_CLOUD_PROJECT is the canonical manner to specify project ID.
    // This is undocumented for appengine custom runtime, but documented for the
    // other runtimes:
    // https://cloud.google.com/appengine/docs/standard/nodejs/runtime
    final projectId = envConfig.googleCloudProject;
    if (projectId == null || projectId.isEmpty) {
      throw StateError(
        'Environment variable \$GOOGLE_CLOUD_PROJECT must be specified!',
      );
    }

    final configFile = envConfig.configPath ??
        path.join(resolveAppDir(), 'config', projectId + '.yaml');
    if (!File(configFile).existsSync()) {
      throw StateError('Could not find configuration file: "$configFile"');
    }
    return Configuration.fromYamlFile(configFile);
  }

  /// Configuration for pkg/fake_pub_server.
  factory Configuration.fakePubServer({
    required int frontendPort,
    required int searchPort,
    required String storageBaseUrl,
  }) {
    return Configuration(
      canonicalPackagesBucketName: 'fake-canonical-packages',
      publicPackagesBucketName: 'fake-public-packages',
      incomingPackagesBucketName: 'fake-incoming-packages',
      projectId: 'dartlang-pub-fake',
      packageBucketName: 'fake-bucket-pub',
      imageBucketName: 'fake-bucket-image',
      dartdocStorageBucketName: 'fake-bucket-dartdoc',
      popularityDumpBucketName: 'fake-bucket-popularity',
      searchSnapshotBucketName: 'fake-bucket-search',
      searchServicePrefix: 'http://localhost:$searchPort',
      storageBaseUrl: storageBaseUrl,
      pubClientAudience: null,
      pubSiteAudience: _fakeSiteAudience,
      adminAudience: null,
      gmailRelayServiceAccount: null, // disable email sending
      gmailRelayImpersonatedGSuiteUser: null, // disable email sending
      uploadSignerServiceAccount: null,
      blockRobots: false,
      productionHosts: ['localhost'],
      primaryApiUri: Uri.parse('http://localhost:$frontendPort/'),
      primarySiteUri: Uri.parse('http://localhost:$frontendPort/'),
      admins: [
        AdminId(
          oauthUserId: 'admin-pub-dev',
          email: 'admin@pub.dev',
          permissions: AdminPermission.values,
        ),
      ],
      tools: null,
    );
  }

  /// Configuration for tests.
  factory Configuration.test({
    String? storageBaseUrl,
    Uri? primaryApiUri,
    Uri? primarySiteUri,
  }) {
    return Configuration(
      canonicalPackagesBucketName: 'fake-canonical-packages',
      publicPackagesBucketName: 'fake-public-packages',
      incomingPackagesBucketName: 'fake-incoming-packages',
      projectId: 'dartlang-pub-test',
      packageBucketName: 'fake-bucket-pub',
      imageBucketName: 'fake-bucket-image',
      dartdocStorageBucketName: 'fake-bucket-dartdoc',
      popularityDumpBucketName: 'fake-bucket-popularity',
      searchSnapshotBucketName: 'fake-bucket-search',
      searchServicePrefix: 'http://localhost:0',
      storageBaseUrl: storageBaseUrl ?? 'http://localhost:0',
      pubClientAudience: null,
      pubSiteAudience: null,
      adminAudience: null,
      gmailRelayServiceAccount: null, // disable email sending
      gmailRelayImpersonatedGSuiteUser: null, // disable email sending
      uploadSignerServiceAccount: null,
      blockRobots: true,
      productionHosts: ['localhost'],
      primaryApiUri: primaryApiUri ?? Uri.parse('https://pub.dartlang.org/'),
      primarySiteUri: primarySiteUri ?? Uri.parse('https://pub.dev/'),
      admins: [
        AdminId(
          oauthUserId: 'admin-pub-dev',
          email: 'admin@pub.dev',
          permissions: AdminPermission.values,
        ),
      ],
      tools: null,
    );
  }

  factory Configuration.fromJson(Map<String, dynamic> json) =>
      _$ConfigurationFromJson(json);
  Map<String, dynamic> toJson() => _$ConfigurationToJson(this);

  /// All the bucket names inside this configuration.
  late final allBucketNames = List<String>.unmodifiable(<String>[
    canonicalPackagesBucketName!,
    dartdocStorageBucketName!,
    imageBucketName!,
    incomingPackagesBucketName!,
    packageBucketName!,
    popularityDumpBucketName!,
    publicPackagesBucketName!,
    searchSnapshotBucketName!,
  ]);
}

/// Data structure to describe an admin user.
@JsonSerializable(
  anyMap: true,
  explicitToJson: true,
  checked: true,
  disallowUnrecognizedKeys: true,
)
class AdminId {
  final String? oauthUserId;
  final String? email;

  /// A set of strings that determine what operations the administrator is
  /// permitted to perform.
  final Set<AdminPermission> permissions;

  AdminId({
    required this.oauthUserId,
    required this.email,
    required Iterable<AdminPermission?> permissions,
  }) : permissions = UnmodifiableSetView(Set.from(permissions));

  factory AdminId.fromJson(Map<String, dynamic> json) =>
      _$AdminIdFromJson(json);
  Map<String, dynamic> toJson() => _$AdminIdToJson(this);
}

/// Permission that can be granted to administrators.
enum AdminPermission {
  /// Permission to execute a tool.
  executeTool,

  /// Permission to list all users.
  listUsers,

  /// Permission to get/set assigned-tags through admin API.
  manageAssignedTags,

  /// Permission to get/set the uploaders of a package.
  managePackageOwnership,

  /// Permission to manage retracted status of a package version.
  manageRetraction,

  /// Permission to remove a package.
  removePackage,

  /// Permission to remove a user account (granted to wipeout).
  removeUsers,
}

/// Configuration related to the local command-line tools (SDKs).
@JsonSerializable(
  explicitToJson: true,
  checked: true,
  disallowUnrecognizedKeys: true,
)
class ToolsConfiguration {
  final String? stableDartSdkPath;
  final String? stableFlutterSdkPath;
  final String? previewDartSdkPath;
  final String? previewFlutterSdkPath;

  ToolsConfiguration({
    required this.stableDartSdkPath,
    required this.stableFlutterSdkPath,
    required this.previewDartSdkPath,
    required this.previewFlutterSdkPath,
  });

  factory ToolsConfiguration.fromJson(Map<String, dynamic> json) =>
      _$ToolsConfigurationFromJson(json);

  Map<String, dynamic> toJson() => _$ToolsConfigurationToJson(this);
}
