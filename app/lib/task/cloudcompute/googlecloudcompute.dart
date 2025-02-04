// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:googleapis/compute/v1.dart' hide Duration;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart' show Logger;
import 'package:meta/meta.dart';
import 'package:pub_dev/shared/utils.dart' show createUuid;
import 'package:pub_dev/task/cloudcompute/cloudcompute.dart';
import 'package:retry/retry.dart';
import 'package:ulid/ulid.dart';

final _log = Logger('pub.googlecloudcompute');

/// Hardcoded list of GCE zones to consider for provisioning.
///
/// See [list of regions and zones][regions-zones].
///
/// [regions-zones]: https://cloud.google.com/compute/docs/regions-zones
const _googleCloudZones = [
  'us-central1-a',
  'us-central1-b',
  'us-central1-c',
  'us-central1-f',
];

/// Hardcoded machine type to use for provisioning instances.
///
/// Note. it is important that this _machine type_ is available in the
/// [_googleCloudZones] listed.
///
/// See [predefined machine-types][machines-types].
///
/// [machine-types]: https://cloud.google.com/compute/docs/machine-types
const _googleCloudMachineType = 'e2-standard-2'; // 2 vCPUs 8GB ram

/// OAuth scope needed for the [http.Client] passed to
/// [createGoogleCloudCompute].
const googleCloudComputeScope = ComputeApi.cloudPlatformScope;

/// Create a [CloudCompute] abstraction wrapping Google Compute Engine.
///
/// The [CloudCompute] abstraction created will manage instance in the given
/// GCP cloud [project] with labels:
///  * `owner = 'pub-dev'`, and,
///  * `pool = poolLabel`.
///
/// Similarly, all instances created by this abstraction will be labelled with
/// `owner` as `'pub-dev'` and `pool` as [poolLabel]. This allows for multiple
/// pools of machines that don't interfere with eachother. By using a
/// [poolLabel] such as `'<runtimeVersion>/pana'` we can ensure that the
/// [CloudCompute] object for pana-tasks doesn't interfere with the other
/// _runtime versions_ in production.
///
/// Instances will use [Container-Optimized OS][c-o-s] to the docker-image
/// specified at instance creation.
///
/// [c-o-s]: https://cloud.google.com/container-optimized-os/docs
CloudCompute createGoogleCloudCompute({
  required http.Client client,
  required String project,
  required String poolLabel,
}) {
  if (poolLabel.isEmpty) {
    throw ArgumentError.value(poolLabel, 'poolLabel', 'must not be empty');
  }

  return _GoogleCloudCompute(
    ComputeApi(client),
    project,
    _googleCloudZones,
    _googleCloudMachineType,
    poolLabel,
  );
}

class _GoogleCloudInstance extends CloudInstance {
  /// GCP zone this instance exists inside.
  @override
  final String zone;

  @override
  final String instanceName;

  @override
  final DateTime created;

  @override
  final InstanceState state;

  _GoogleCloudInstance(
    this.zone,
    this.instanceName,
    this.created,
    this.state,
  );

  @override
  String toString() {
    return 'GoogleCloudInstance($instanceName, zone: $zone, created: $created, state: $state)';
  }
}

class _PendingGoogleCloudInstance extends CloudInstance {
  /// GCP zone this instance exists inside.
  @override
  final String zone;

  @override
  final String instanceName;

  @override
  DateTime get created => clock.now();

  @override
  InstanceState get state => InstanceState.pending;

  _PendingGoogleCloudInstance(this.zone, this.instanceName);

  @override
  String toString() {
    return 'GoogleCloudInstance($instanceName, zone: $zone, created: $created, state: $state)';
  }
}

Future<T> _retryWithRequestId<T>(Future<T> Function(String rId) fn) async {
  // As long as we use the same requestId we can call multiple times without
  // duplicating side-effects on the server (at-least this seems plausible).
  final requestId = createUuid();

  return await _retry(() => fn(requestId));
}

Future<T> _retry<T>(Future<T> Function() fn) async {
  return await retry(
    fn,
    retryIf: (e) =>
        // Guessing the API might honor: https://google.aip.dev/194
        // So only retry 'UNAVAILABLE' errors, which is 503 according to:
        // https://github.com/googleapis/api-common-protos/blob/master/google/rpc/code.proto
        (e is DetailedApiRequestError && e.status == 503) ||
        // In addition we retry undocumented errors and malformed responses.
        (e is ApiRequestError && e is! DetailedApiRequestError) ||
        // If there is a timeout, we also retry.
        e is TimeoutException ||
        // Finally, we retry all I/O issues.
        e is IOException,
  );
}

/// Pattern for valid GCE instance names.
final _validInstanceNamePattern = RegExp(r'^[a-z]([-a-z0-9]*[a-z0-9])?$');

@sealed
class _GoogleCloudCompute extends CloudCompute {
  final ComputeApi _api;

  /// GCP project this isntance is managing VMs inside.
  final String _project;

  /// GCP zones this instance is managing VMs inside.
  final List<String> _zones;

  /// GCP machine type, see:
  /// https://cloud.google.com/compute/docs/machine-types
  final String _machineType;

  /// Value of the `pool` label for VMs managed by this instance.
  ///
  /// Instances created must have this `pool` label, same goes for instances
  /// listed (luckily we can filter in labels in the API).
  final String _poolLabel;

  /// Instances where a [Future] from the [createInstance] operation is still
  /// waiting to be resolved.
  ///
  /// We shall show such instances in [listInstances] until the [Future]
  /// returned frm [createInstance] has been resolved.
  final Set<_PendingGoogleCloudInstance> _pendingInstances = {};

  _GoogleCloudCompute(
    this._api,
    this._project,
    this._zones,
    this._machineType,
    this._poolLabel,
  );

  @override
  List<String> get zones => List.from(_zones);

  @override
  String generateInstanceName() => 'worker-${Ulid()}';

  @override
  Future<CloudInstance> createInstance({
    required String zone,
    required String instanceName,
    required String dockerImage,
    required List<String> arguments,
    required String description,
  }) async {
    if (!_zones.contains(zone)) {
      throw ArgumentError.value(
        zone,
        'zone',
        'must be one of CloudCompute.zones',
      );
    }
    if (instanceName.isEmpty || instanceName.length > 63) {
      throw ArgumentError.value(
          instanceName, 'instanceName', 'must have a length between 1 and 63');
    }
    if (!_validInstanceNamePattern.hasMatch(instanceName)) {
      throw ArgumentError.value(instanceName, 'instanceName',
          'must match pattern: $_validInstanceNamePattern');
    }
    // Max argument string size on Linux is MAX_ARG_STRLEN = 131072
    // In addition the maximum meta-data size supported by GCE is 256KiB
    // We need a few extra bits, so we shall enforce a max size of 100KiB.
    final argumentsLengthInBytes = arguments
        .map(utf8.encode)
        .map((s) => s.length)
        .fold<int>(0, (a, b) => a + b);
    if (argumentsLengthInBytes > 100 * 1024) {
      throw ArgumentError.value(
        arguments,
        'arguments',
        'must be less than 100KiB',
      );
    }

    final cmd = [
      '/usr/bin/docker',
      'run',
      '--rm',
      '-u',
      '2000',
      '--name',
      'task',
      dockerImage,
      ...arguments
    ];
    final cloudConfig = [
      '#cloud-config',
      'users:',
      '- name: worker',
      '  uid: 2000',
      'runcmd:',
      '- ${json.encode(cmd)}',
      '- [\'/sbin/shutdown\', \'now\']',
      '',
    ].join('\n');

    final instance = Instance()
      ..name = instanceName
      ..description = description
      ..machineType = 'zones/$zone/machineTypes/$_machineType'
      ..scheduling = (Scheduling()..preemptible = true)
      ..labels = {
        // Labels that allows us to filter instances when listing instances.
        'owner': 'pub-dev',
        'pool': _poolLabel,
      }
      ..metadata = (Metadata()
        ..items = [
          MetadataItems()
            ..key = 'user-data'
            ..value = cloudConfig,
        ])
      ..serviceAccounts = []
      ..networkInterfaces = [
        NetworkInterface()
          ..network = 'global/networks/default'
          ..accessConfigs = [
            AccessConfig()
              ..type = 'ONE_TO_ONE_NAT'
              ..name = 'External NAT',
          ],
      ]
      ..disks = [
        AttachedDisk()
          ..type = 'PERSISTENT'
          ..boot = true
          ..autoDelete = true
          ..initializeParams = (AttachedDiskInitializeParams()
            ..labels = {
              // Labels allows to track disks, in practice they should always
              // be auto-deleted with instance, but if this fails it's nice to
              // have a label.
              'owner': 'pub-dev',
              'pool': _poolLabel,
            }
            ..sourceImage =
                'projects/cos-cloud/global/images/family/cos-stable'),
      ];

    _log.info('Creating instance: ${instance.name}');
    final pendingInstancePlaceHolder =
        _PendingGoogleCloudInstance(zone, instanceName);
    _pendingInstances.add(pendingInstancePlaceHolder);
    try {
      // https://cloud.google.com/container-optimized-os/docs/how-to/create-configure-instance#creating_an_instance
      var op = await _retryWithRequestId((rId) => _api.instances
          .insert(
            instance,
            _project,
            zone,
            requestId: rId,
          )
          .timeout(Duration(minutes: 5)));

      void logWarningsThrowErrors() {
        // Log warnings if there is any
        final warnings = op.warnings;
        if (warnings != null) {
          for (final w in warnings) {
            _log.warning(
              'Warning while creating instance, '
              'api.instances.insert(name=${instance.name}) '
              '${w.code}: ${w.message}',
            );
          }
        }

        // Throw first error.
        final opError = op.error;
        if (opError != null) {
          final opErrors = opError.errors;
          if (opErrors != null && opErrors.isNotEmpty) {
            throw ApiRequestError(
              'Error creating instance, '
              'api.instances.insert(name=${instance.name}), '
              '${opErrors.first.code}: ${opErrors.first.message}',
            );
          }
        }
      }

      // Check if we got any errors
      logWarningsThrowErrors();

      while (op.status != 'DONE') {
        final start = clock.now();
        op = await _retry(() => _api.zoneOperations
            .wait(
              _project,
              zone,
              op.name!,
            )
            .timeout(Duration(minutes: 3)));
        logWarningsThrowErrors();

        if (op.status != 'DONE') {
          // Ensure at-least two minutes between api.zoneOperations.wait() calls
          final elapsed = clock.now().difference(start);
          final remainder = Duration(minutes: 2) - elapsed;
          if (!remainder.isNegative) {
            await Future.delayed(remainder);
          }
        }
      }
      _log.info('Created instance: ${instance.name}');

      return _wrapInstanceWithState(
        instance,
        zone,
        DateTime.tryParse(op.creationTimestamp ?? '') ?? DateTime(0),
        InstanceState.pending,
      );
    } finally {
      _pendingInstances.remove(pendingInstancePlaceHolder);
    }
  }

  @override
  Future<void> delete(String zone, String instanceName) async {
    await _retryWithRequestId((rId) => _api.instances.delete(
          _project,
          zone,
          instanceName,
          requestId: rId,
        ));
    // Note. that instances.delete() technically returns a custom long-running
    // operation, we have no reasonable action to take if deletion fails.
    // Presumably, the instance would show up in listings again and eventually
    // be deleted once more (with a new operation, with a new requestId).
    // TODO: Await the delete operation...
  }

  @override
  Stream<CloudInstance> listInstances() {
    final filter = [
      'labels.owner = "pub-dev"',
      'labels.pool = "$_poolLabel"',
    ].join(' AND ');

    final c = StreamController<CloudInstance>();

    scheduleMicrotask(() async {
      try {
        await Future.wait(_zones.map((zone) async {
          var response = await _retry(() => _api.instances.list(
                _project,
                zone,
                maxResults: 500,
                filter: filter,
              ));

          final wrap = (Instance item) => _wrapInstance(item, zone);
          final pendingInZone = _pendingInstances
              .where((instance) => instance.zone == zone)
              .toSet();

          for (final instance in (response.items ?? []).map(wrap)) {
            c.add(instance);
            pendingInZone
                .removeWhere((i) => i.instanceName == instance.instanceName);
          }

          while ((response.nextPageToken ?? '').isNotEmpty) {
            response = await _retry(() => _api.instances.list(
                  _project,
                  zone,
                  maxResults: 500,
                  filter: filter,
                  pageToken: response.nextPageToken,
                ));
            for (final instance in (response.items ?? []).map(wrap)) {
              c.add(instance);
              pendingInZone
                  .removeWhere((i) => i.instanceName == instance.instanceName);
            }
          }

          // For each of the pending instances in current zone, where name has
          // not been reported, return the fake pending instance.
          pendingInZone.forEach(c.add);
        }));
      } catch (e, st) {
        c.addError(e, st);
      } finally {
        await c.close();
      }
    });

    return c.stream;
  }

  CloudInstance _wrapInstance(Instance instance, String zone) {
    DateTime created;
    try {
      created = DateTime.parse(instance.creationTimestamp ?? '');
    } on FormatException {
      // Print error and instance to log..
      _log.severe(
        'Failed to parse instance.creationTimestamp: '
        '"${instance.creationTimestamp}"',
      );
      // Fallback to year zero that way instances will be killed.
      created = DateTime(0);
    }

    InstanceState state;
    switch (instance.status) {
      // See: https://cloud.google.com/compute/docs/instances/instance-life-cycle
      // Note that the API specifies that it may return 'SUSPENDING' and
      // 'SUSPENDED' even though these are undocumented by the life-cycle docs.
      case 'PROVISIONING':
      case 'STAGING':
        state = InstanceState.pending;
        break;
      case 'RUNNING':
        state = InstanceState.running;
        break;
      case 'REPAIRING':
      case 'STOPPING':
      case 'STOPPED':
      case 'SUSPENDING': // Undocumented state
      case 'SUSPENDED': // Undocumented state
      case 'TERMINATED':
        state = InstanceState.terminated;
        break;
      default:
        // Unless this happens frequently, it's probably not so bad to always
        // just treat the instance as dead, and wait for clean-up process to
        // kill it.
        _log.severe('Unhandled instance.status="${instance.status}", '
            'reason: ${instance.statusMessage}');
        state = InstanceState.terminated;
    }
    return _wrapInstanceWithState(instance, zone, created, state);
  }

  CloudInstance _wrapInstanceWithState(
    Instance instance,
    String zone,
    DateTime created,
    InstanceState state,
  ) =>
      _GoogleCloudInstance(
        zone,
        instance.name ?? '',
        created,
        state,
      );
}
