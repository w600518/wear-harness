/*
 * relay_probe.dart - drives the Dart relay client against a running C server.
 *
 * The unit tests prove the Dart and C crypto agree byte for byte. This probe
 * proves the other half: that the Dart client's handshake, framing, request
 * envelope and error handling interoperate with the shipped C server and a C
 * sender over a real socket.
 *
 * Usage:
 *   dart run tool/relay_probe.dart [host] [port] [passphrase]
 */
import 'dart:async';
import 'dart:io';

import 'package:client_wear/relay/relay_client.dart';

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '127.0.0.1';
  final port = args.length > 1 ? int.parse(args[1]) : 7777;
  final passphrase = args.length > 2 ? args[2] : 'test-passphrase-123';

  final client = RelayClient(
    config: RelayConfig(
      host: host,
      port: port,
      passphrase: passphrase,
      deviceName: 'dart-probe',
    ),
  );

  final seen = <String, int>{};
  final devices = <Map<String, dynamic>>[];
  final subscriptions = <StreamSubscription<RelayMessage>>[];

  subscriptions.add(client.messages.listen((message) {
    seen[message.kind] = (seen[message.kind] ?? 0) + 1;
    if (message.kind == 'devices') {
      final list = message.payload?['devices'];
      if (list is List) {
        devices
          ..clear()
          ..addAll(list.whereType<Map<String, dynamic>>());
      }
    }
  }));

  var failures = 0;

  try {
    stdout.writeln('connecting to $host:$port');
    await client.connect();
    stdout.writeln('handshake ok, session keys derived');

    /* The server pushes the roster right after the handshake. */
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    stdout.writeln('devices: ${devices.length}');
    for (final device in devices) {
      stdout.writeln('  - ${device['id']}  dsh=${device['dshVersion']}');
    }

    if (devices.isEmpty) {
      stdout.writeln('FAIL: no sender is online');
      failures++;
    }

    /* A request answered by the sender itself: no dsh involvement needed. */
    final status = await client.request('relay/status');
    stdout.writeln('relay/status -> $status');
    if (status['dshReachable'] != true) {
      stdout.writeln('note: the sender has no authenticated dsh connection');
    }

    /* A dsh-backed request: proves the whole chain reaches the harness. */
    final catalog = await client.request('session/modelCatalog');
    final defaultModel = catalog['default'];
    stdout.writeln('session/modelCatalog -> default=$defaultModel');
    if (defaultModel == null) {
      stdout.writeln('FAIL: model catalog came back empty');
      failures++;
    }

    final value = await client.request('sessions/list');
    final items = value['items'];
    final count = items is List ? items.length : 0;
    stdout.writeln('sessions/list -> $count sessions');
    if (count == 0) {
      stdout.writeln('FAIL: session list came back empty');
      failures++;
    }

    /* An error path: the code must survive the C layers intact. */
    try {
      await client.request('session/page', payload: {
        'sessionId': 'session-00000000-0000-4000-8000-000000000000',
        'throughSeq': 1,
      });
      stdout.writeln('FAIL: a request for a missing session succeeded');
      failures++;
    } on RelayException catch (error) {
      stdout.writeln('missing session -> ${error.code}');
      if (error.code != 'session/not-found') {
        stdout.writeln('FAIL: expected session/not-found, got ${error.code}');
        failures++;
      }
    }
  } on Object catch (error) {
    stdout.writeln('FAIL: $error');
    failures++;
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await client.dispose();
  }

  stdout.writeln('');
  stdout.writeln('message kinds seen: $seen');
  stdout.writeln(failures == 0
      ? 'PASS: the Dart client interoperates with the C server'
      : 'FAIL: $failures check(s) failed');
  exit(failures == 0 ? 0 : 1);
}
