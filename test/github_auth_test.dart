import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mobilecode/data/secure/credential_store.dart';
import 'package:mobilecode/features/github/github_auth.dart';
import 'package:mobilecode/features/github/github_device_flow.dart';

/// Scripts a sequence of responses, so a poll can fail the way a phone's
/// network actually fails.
GithubAuthController controllerFor(
  List<FutureOr<http.Response> Function()> responses, {
  CredentialStore? store,
}) {
  var call = 0;
  final client = MockClient((request) async {
    final handler = responses[call.clamp(0, responses.length - 1)];
    call++;
    return handler();
  });

  return GithubAuthController(
    credentials: store ?? InMemoryCredentialStore(),
    deviceFlow: GithubDeviceFlow(clientId: 'test', httpClient: client),
  );
}

http.Response json(Map<String, Object?> body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

/// Poll immediately so tests do not wait on GitHub's real interval.
final grantBody = <String, Object?>{
  'device_code': 'device-code',
  'user_code': 'WDJB-MJHT',
  'verification_uri': 'https://github.com/login/device',
  'interval': 0,
  'expires_in': 900,
};

Future<void> waitFor(GithubAuthController controller, bool Function() done) {
  if (done()) return Future.value();
  final completer = Completer<void>();
  void listener() {
    if (done() && !completer.isCompleted) completer.complete();
  }

  controller.addListener(listener);
  return completer.future
      .timeout(const Duration(seconds: 5))
      .whenComplete(() => controller.removeListener(listener));
}

void main() {
  test('signs in when GitHub grants the token', () async {
    final store = InMemoryCredentialStore();
    final controller = controllerFor(
      [
        () => json(grantBody),
        () => json({'access_token': 'gho_example'}),
      ],
      store: store,
    );
    addTearDown(controller.dispose);

    await controller.signIn();
    await waitFor(controller, () => controller.status == GithubAuthStatus.signedIn);

    expect(controller.token, 'gho_example');
    expect(await store.read(CredentialStore.githubTokenRef), 'gho_example');
  });

  test('survives a dropped connection mid-poll', () async {
    // Exactly the reported failure: "Software caused connection abort" on
    // /login/oauth/access_token. A phone loses connectivity constantly over a
    // fifteen-minute window, and one dropped request must not end sign-in.
    final controller = controllerFor([
      () => json(grantBody),
      () => throw const SocketException('Software caused connection abort'),
      () => json({'access_token': 'gho_after_recovery'}),
    ]);
    addTearDown(controller.dispose);

    await controller.signIn();
    await waitFor(controller, () => controller.status == GithubAuthStatus.signedIn);

    expect(controller.token, 'gho_after_recovery');
  });

  test('keeps the user code visible across a transport failure', () async {
    // Regression guard: the code the user is typing must not vanish because a
    // background poll blipped.
    final controller = controllerFor([
      () => json(grantBody),
      () => throw const SocketException('connection reset'),
      () => json({'error': 'authorization_pending'}),
      () => json({'access_token': 'gho_ok'}),
    ]);
    addTearDown(controller.dispose);

    await controller.signIn();
    expect(controller.grant?.userCode, 'WDJB-MJHT');

    await waitFor(controller, () => controller.status == GithubAuthStatus.signedIn);
    expect(controller.token, 'gho_ok');
  });

  test('still fails when GitHub itself declines', () async {
    // Transport failures retry; a real answer from GitHub is final.
    final controller = controllerFor([
      () => json(grantBody),
      () => json({'error': 'access_denied'}),
    ]);
    addTearDown(controller.dispose);

    await controller.signIn();
    await waitFor(controller, () => controller.status == GithubAuthStatus.failed);

    expect(controller.errorMessage, contains('declined'));
  });

  test('stops retrying once the code has expired', () async {
    final controller = controllerFor([
      () => json({...grantBody, 'expires_in': 0}),
      () => throw const SocketException('down'),
    ]);
    addTearDown(controller.dispose);

    await controller.signIn();
    await waitFor(controller, () => controller.status == GithubAuthStatus.failed);

    expect(controller.errorMessage, contains('expired'));
  });

  test('restores a stored token without asking GitHub', () async {
    final store = InMemoryCredentialStore();
    await store.write(CredentialStore.githubTokenRef, 'gho_saved');

    final controller = controllerFor([() => json(grantBody)], store: store);
    addTearDown(controller.dispose);

    await controller.restore();
    expect(controller.status, GithubAuthStatus.signedIn);
    expect(controller.token, 'gho_saved');
  });

  test('sign out clears the stored token', () async {
    final store = InMemoryCredentialStore();
    await store.write(CredentialStore.githubTokenRef, 'gho_saved');

    final controller = controllerFor([() => json(grantBody)], store: store);
    addTearDown(controller.dispose);

    await controller.restore();
    await controller.signOut();

    expect(controller.status, GithubAuthStatus.signedOut);
    expect(await store.read(CredentialStore.githubTokenRef), isNull);
  });
}
