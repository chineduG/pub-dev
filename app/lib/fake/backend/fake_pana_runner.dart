// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pana/pana.dart';
import 'package:pub_semver/pub_semver.dart';

import '../../analyzer/pana_runner.dart';
import '../../scorecard/backend.dart' show PackageStatus;
import '../../shared/versions.dart';

/// Runs package analysis for all packages with fake pana runner.
Future<void> processJobsWithFakePanaRunner() async {
  // ignore: invalid_use_of_visible_for_testing_member
  await processJobsWithPanaRunner(runner: FakePanaRunner());
}

/// Generates pana analysis result based on a deterministic random seed.
class FakePanaRunner implements PanaRunner {
  @override
  Future<Summary> analyze({
    required String package,
    required String version,
    required PackageStatus packageStatus,
  }) async {
    final hasher = createHasher([package, version].join('/'));
    final layoutPoints = hasher('points/layout', max: 30);
    final examplePoints = hasher('points/example', max: 30);
    final hasSdkDart = hasher('sdk:dart', max: 10) > 0;
    final hasSdkFlutter =
        hasher('sdk:flutter', max: packageStatus.usesFlutter ? 20 : 10) > 0;
    final hasValidSdk = hasSdkDart || hasSdkFlutter;
    final runtimeTags = hasSdkDart
        ? <String>[
            'runtime:native-aot',
            'runtime:native-jit',
            'runtime:web',
          ].where((p) => hasher(p, max: 5) > 0).toList()
        : <String>[];
    final platformTags = hasValidSdk
        ? <String>[
            'platform:android',
            'platform:ios',
            'platform:linux',
            'platform:macos',
            'platform:web',
            'platform:windows',
          ].where((p) => hasher(p, max: 5) > 0).toList()
        : <String>[];
    final licenseSpdx =
        hasher('license', max: 5) == 0 ? 'unknown' : 'BSD-3-Clause';
    return Summary(
      packageName: package,
      packageVersion: Version.parse(version),
      runtimeInfo: PanaRuntimeInfo(
        sdkVersion: packageStatus.usesPreviewAnalysisSdk
            ? toolPreviewDartSdkVersion
            : toolStableDartSdkVersion,
        panaVersion: panaVersion,
        flutterVersions: {},
      ),
      allDependencies: <String>[],
      tags: <String>[
        if (hasSdkDart) 'sdk:dart',
        if (hasSdkFlutter) 'sdk:flutter',
        ...runtimeTags,
        ...platformTags,
        'license:${licenseSpdx.toLowerCase()}',
        if (licenseSpdx != 'unknown') 'license:fsf-libre',
        if (licenseSpdx != 'unknown') 'license:osi-approved',
      ],
      report: Report(
        sections: [
          ReportSection(
            id: ReportSectionId.convention,
            title: 'Fake conventions',
            grantedPoints: layoutPoints,
            maxPoints: 30,
            summary: renderSimpleSectionSummary(
              title: 'Package layout',
              description:
                  'Package layout score randomly set to $layoutPoints...',
              grantedPoints: layoutPoints,
              maxPoints: 30,
            ),
            status:
                layoutPoints > 20 ? ReportStatus.passed : ReportStatus.failed,
          ),
          ReportSection(
            id: ReportSectionId.documentation,
            title: 'Fake documentation',
            grantedPoints: examplePoints,
            maxPoints: 30,
            summary: renderSimpleSectionSummary(
              title: 'Example',
              description: 'Example score randomly set to $examplePoints...',
              grantedPoints: examplePoints,
              maxPoints: 30,
            ),
            status:
                examplePoints > 20 ? ReportStatus.passed : ReportStatus.partial,
          ),
        ],
      ),
      licenseFile: LicenseFile('LICENSE', licenseSpdx),
      licenses: [
        License(path: 'LICENSE', spdxIdentifier: licenseSpdx),
      ],
      errorMessage: null,
      pubspec: null, // will be ignored
    );
  }
}

/// Returns the hash of the [key]. When [max] is present, only
/// ints between 0 and max (exclusive) will be returned.
///
/// Throws [StateError] if it is called more than once with teh same [key].
typedef Hasher = int Function(String key, {int? max});

/// Creates a [Hasher] using the provided [seed].
Hasher createHasher(String seed) {
  final _keys = <String>{};
  return (key, {int? max}) {
    if (!_keys.add(key)) {
      throw StateError('Key "$key" already used.');
    }
    final content = [seed, key].join('/');
    final contentHash = sha256.convert(utf8.encode(content));
    final bytes = contentHash.bytes;
    final hash = (bytes[0] << 16) + (bytes[1] << 8) + bytes[2];
    return max == null ? hash : (hash % max);
  };
}
