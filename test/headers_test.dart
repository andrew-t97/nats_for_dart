/// Integration tests for core pub/sub message headers.
///
/// Covers publish/request/respond + sync and async subscription paths,
/// the headerless fast path, and the `serverSupportsHeaders` getter.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:nats_for_dart/nats_for_dart.dart';
import 'package:test/test.dart';

import 'support/docker_nats.dart';

void main() {
  late DockerNats nats;

  setUpAll(() async {
    nats = await DockerNats.start();
    NatsLibrary.init();
  });

  tearDownAll(() async {
    NatsLibrary.close(timeoutMs: 5000);
    await nats.stop();
  });

  group('Core pub/sub headers', () {
    late NatsClient client;

    setUp(() {
      client = NatsClient.connect(nats.url);
    });

    tearDown(() async => await client.close());

    String subject(String tag) =>
        'test.headers.$tag.${DateTime.now().microsecondsSinceEpoch}';

    Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

    test('single-value header round-trips on the sync path', () {
      final subj = subject('single');
      final sub = client.subscribeSync(subj);
      addTearDown(sub.close);

      final headers = NatsHeaders.from({'X-Trace-Id': 'abc-123'});
      client.publish(subj, 'hello', headers: headers);

      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.headers.firstOrNull('X-Trace-Id'), equals('abc-123'));
      expect(msg.headers.getAll('X-Trace-Id'), equals(['abc-123']));
      expect(msg.dataAsString, equals('hello'));
    });

    test('multi-value header preserves Add insertion order', () {
      final subj = subject('multi');
      final sub = client.subscribeSync(subj);
      addTearDown(sub.close);

      final headers = NatsHeaders.from({
        'X-Tag': ['first', 'second'],
      });
      client.publish(subj, 'multi', headers: headers);

      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.headers.getAll('X-Tag'), equals(['first', 'second']));
    });

    test('no headers — receivedHeaders == NatsHeaders.empty()', () {
      final subj = subject('none');
      final sub = client.subscribeSync(subj);
      addTearDown(sub.close);

      client.publish(subj, 'plain');

      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.headers.isEmpty, isTrue);
      expect(msg.headers, equals(const NatsHeaders.empty()));
    });

    test('empty header value round-trips', () {
      final subj = subject('emptyvalue');
      final sub = client.subscribeSync(subj);
      addTearDown(sub.close);

      final headers = NatsHeaders.from({'X-Empty': ''});
      client.publish(subj, 'data', headers: headers);

      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.headers.containsKey('X-Empty'), isTrue);
      expect(msg.headers.firstOrNull('X-Empty'), equals(''));
    });

    test('8 KB long value round-trips intact', () {
      final subj = subject('long');
      final sub = client.subscribeSync(subj);
      addTearDown(sub.close);

      final longValue = 'x' * 8192;
      final headers = NatsHeaders.from({'X-Bulk': longValue});
      client.publish(subj, 'long', headers: headers);

      final msg = sub.nextMessage(timeout: const Duration(seconds: 5));
      expect(msg.headers.firstOrNull('X-Bulk'), equals(longValue));
    });

    test('64 keys round-trip intact', () {
      final subj = subject('manykeys');
      final sub = client.subscribeSync(subj);
      addTearDown(sub.close);

      final pairs = <String, String>{
        for (var i = 0; i < 64; i++) 'X-Key-$i': 'v$i',
      };
      final headers = NatsHeaders.from(pairs);
      client.publish(subj, 'many', headers: headers);

      final msg = sub.nextMessage(timeout: const Duration(seconds: 5));
      for (var i = 0; i < 64; i++) {
        expect(msg.headers.firstOrNull('X-Key-$i'), equals('v$i'));
      }
    });

    test('async-path round-trip via subscribe stream', () async {
      final subj = subject('async');
      final sub = client.subscribe(subj);
      addTearDown(sub.close);

      final headers = NatsHeaders.from({'X-Trace-Id': 'async-1'});
      client.publish(subj, 'async-data', headers: headers);
      client.flush();

      final msg = await sub.messages.first.timeout(const Duration(seconds: 2));
      expect(msg.headers.firstOrNull('X-Trace-Id'), equals('async-1'));
      expect(msg.dataAsString, equals('async-data'));
    });

    test('publishBytes carries headers', () async {
      final subj = subject('bytes');
      final sub = client.subscribe(subj);
      addTearDown(sub.close);

      final headers = NatsHeaders.from({'X-Encoding': 'binary'});
      client.publishBytes(subj, bytes('payload'), headers: headers);
      client.flush();

      final msg = await sub.messages.first.timeout(const Duration(seconds: 2));
      expect(msg.headers.firstOrNull('X-Encoding'), equals('binary'));
      expect(msg.dataAsString, equals('payload'));
    });

    test('request with headers — responder observes them', () async {
      final subj = subject('req');
      final responderSub = client.subscribe(subj);
      addTearDown(responderSub.close);

      responderSub.messages.listen((req) {
        final traceId = req.headers.firstOrNull('X-Trace-Id') ?? 'missing';
        client.respond(req, 'observed:$traceId');
      });
      client.flush();

      final headers = NatsHeaders.from({'X-Trace-Id': 'req-42'});
      final reply = await client.request(subj, 'ping', headers: headers);
      expect(reply.dataAsString, equals('observed:req-42'));
    });

    test('respond with headers — requester observes them on reply', () async {
      final subj = subject('respond');
      final responderSub = client.subscribe(subj);
      addTearDown(responderSub.close);

      responderSub.messages.listen((req) {
        client.respond(
          req,
          'pong',
          headers: NatsHeaders.from({'X-Reply-Trace': 'rsp-7'}),
        );
      });
      client.flush();

      final reply = await client.request(subj, 'ping');
      expect(reply.dataAsString, equals('pong'));
      expect(reply.headers.firstOrNull('X-Reply-Trace'), equals('rsp-7'));
    });

    test('request against no-responders subject WITH headers still throws '
        'NatsNoRespondersException', () async {
      final subj = subject('noresp');
      final headers = NatsHeaders.from({'X-Trace-Id': 'noresp-9'});

      await expectLater(
        client.request(subj, 'ping', headers: headers),
        throwsA(isA<NatsNoRespondersException>()),
      );
    });

    test('headerless request still throws NatsNoRespondersException '
        '(fast-path regression pin)', () async {
      final subj = subject('noresp_plain');

      await expectLater(
        client.request(subj, 'ping'),
        throwsA(isA<NatsNoRespondersException>()),
      );
    });

    test('serverSupportsHeaders is true against DockerNats', () {
      expect(client.serverSupportsHeaders, isTrue);
    });

    test('equality on the wire — single-value round-trip', () {
      final subj = subject('eq');
      final sub = client.subscribeSync(subj);
      addTearDown(sub.close);

      final sent = NatsHeaders.from({'X-One': '1'});
      client.publish(subj, 'eq', headers: sent);

      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.headers, equals(sent));
    });

    test(
      'respondBytes with headers — reply payload + headers intact',
      () async {
        final subj = subject('respondbytes');
        final responderSub = client.subscribe(subj);
        addTearDown(responderSub.close);

        responderSub.messages.listen((req) {
          client.respondBytes(
            req,
            bytes('binary-pong'),
            headers: NatsHeaders.from({'X-Reply-Encoding': 'binary'}),
          );
        });
        client.flush();

        final reply = await client.requestBytes(subj, bytes('binary-ping'));
        expect(reply.dataAsString, equals('binary-pong'));
        expect(reply.headers.firstOrNull('X-Reply-Encoding'), equals('binary'));
      },
    );

    test('explicit empty headers takes the fast path identically', () {
      final subj = subject('headerless');
      final sub = client.subscribeSync(subj);
      addTearDown(sub.close);

      client.publish(subj, 'no-headers', headers: const NatsHeaders.empty());

      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.headers.isEmpty, isTrue);
      expect(msg.dataAsString, equals('no-headers'));
    });
  });
}
