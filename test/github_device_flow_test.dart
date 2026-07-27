import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mobilecode/features/github/github_device_flow.dart';

GithubDeviceFlow flowReturning(
  Object body, {
  int status = 200,
  void Function(http.Request request)? inspect,
}) {
  return GithubDeviceFlow(
    clientId: 'test-client',
    httpClient: MockClient((request) async {
      inspect?.call(request);
      return http.Response(
        body is String ? body : jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
}

void main() {
  group('requestCode', () {
    test('reads the grant', () async {
      final flow = flowReturning(const {
        'device_code': 'secret-half',
        'user_code': 'WDJB-MJHT',
        'verification_uri': 'https://github.com/login/device',
        'interval': 5,
        'expires_in': 900,
      });

      final grant = await flow.requestCode();
      expect(grant.deviceCode, 'secret-half');
      expect(grant.userCode, 'WDJB-MJHT');
      expect(grant.interval, const Duration(seconds: 5));
      expect(grant.expiresIn, const Duration(seconds: 900));
    });

    test('asks for the scopes Codespaces needs', () async {
      String? sentBody;
      final flow = flowReturning(
        const {
          'device_code': 'd',
          'user_code': 'u',
          'verification_uri': 'https://github.com/login/device',
        },
        inspect: (request) => sentBody = request.body,
      );

      await flow.requestCode();
      // Without `codespace` the API returns 403 on every Codespaces call, and
      // the user would have to sign in again to fix it.
      expect(sentBody, contains('codespace'));
      expect(sentBody, contains('repo'));
    });

    test('refuses to start with no client id', () async {
      final flow = GithubDeviceFlow(clientId: '');
      expect(flow.isConfigured, isFalse);
      await expectLater(
        flow.requestCode(),
        throwsA(isA<GithubAuthException>()),
      );
    });

    test('surfaces a refusal rather than a null grant', () async {
      final flow = flowReturning(
        const {'error': 'unauthorized_client'},
        status: 401,
      );
      await expectLater(
        flow.requestCode(),
        throwsA(isA<GithubAuthException>()),
      );
    });
  });

  group('poll', () {
    test('keeps waiting while the user has not finished', () async {
      final flow = flowReturning(const {'error': 'authorization_pending'});
      final result = await flow.poll('d');
      expect(result.state, DevicePollState.pending);
      expect(result.token, isNull);
    });

    test('honours a slow_down with the interval GitHub supplies', () async {
      // Ignoring slow_down escalates to a hard failure, so the new interval
      // has to replace ours rather than be treated as advisory.
      final flow = flowReturning(
        const {'error': 'slow_down', 'interval': 17},
      );
      final result = await flow.poll('d');
      expect(result.state, DevicePollState.slowDown);
      expect(result.interval, const Duration(seconds: 17));
    });

    test('falls back to a sane backoff when slow_down omits the interval',
        () async {
      final flow = flowReturning(const {'error': 'slow_down'});
      final result = await flow.poll('d');
      expect(result.interval, isNotNull);
      expect(result.interval!.inSeconds, greaterThan(0));
    });

    test('returns the token once granted', () async {
      final flow = flowReturning(const {
        'access_token': 'gho_example',
        'token_type': 'bearer',
      });
      final result = await flow.poll('d');
      expect(result.state, DevicePollState.granted);
      expect(result.token, 'gho_example');
    });

    test('distinguishes expiry from denial', () async {
      expect(
        (await flowReturning(const {'error': 'expired_token'}).poll('d')).state,
        DevicePollState.expired,
      );
      expect(
        (await flowReturning(const {'error': 'access_denied'}).poll('d')).state,
        DevicePollState.denied,
      );
    });

    test('throws on an error it does not model', () async {
      final flow = flowReturning(const {
        'error': 'incorrect_client_credentials',
        'error_description': 'bad client id',
      });
      await expectLater(flow.poll('d'), throwsA(isA<GithubAuthException>()));
    });

    test('treats a non-JSON body as an unknown failure, not a crash', () async {
      // GitHub serves HTML for rate limiting and outages.
      final flow = flowReturning('<html>rate limited</html>');
      await expectLater(flow.poll('d'), throwsA(isA<GithubAuthException>()));
    });
  });
}
