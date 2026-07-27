import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:mobilecode/data/secure/credential_store.dart';
import 'package:mobilecode/features/github/github_device_flow.dart';

enum GithubAuthStatus {
  /// No token stored.
  signedOut,

  /// Waiting for GitHub to hand us a user code.
  requestingCode,

  /// Showing the code; the user is authorising in a browser.
  awaitingUser,

  signedIn,
  failed,
}

/// Owns the GitHub token and the device-flow handshake.
class GithubAuthController extends ChangeNotifier {
  GithubAuthController({
    required this.credentials,
    required this.deviceFlow,
  });

  final CredentialStore credentials;
  final GithubDeviceFlow deviceFlow;

  GithubAuthStatus status = GithubAuthStatus.signedOut;
  DeviceCodeGrant? grant;
  String? token;
  String? errorMessage;

  Timer? _poller;

  /// When the device code stops being valid. Transient poll failures are
  /// retried until this passes.
  DateTime? _expiresAt;

  bool get isConfigured => deviceFlow.isConfigured;

  /// Loads a previously stored token, if any.
  Future<void> restore() async {
    token = await credentials.read(CredentialStore.githubTokenRef);
    status = token == null ? GithubAuthStatus.signedOut
                           : GithubAuthStatus.signedIn;
    notifyListeners();
  }

  Future<void> signIn() async {
    _poller?.cancel();
    errorMessage = null;
    _set(GithubAuthStatus.requestingCode);

    try {
      final grant = this.grant = await deviceFlow.requestCode();
      _expiresAt = DateTime.now().add(grant.expiresIn);
      _set(GithubAuthStatus.awaitingUser);
      _schedulePoll(grant, grant.interval);
    } catch (error) {
      errorMessage = error.toString();
      _set(GithubAuthStatus.failed);
    }
  }

  /// Polls on GitHub's schedule rather than a fixed timer.
  ///
  /// The interval is theirs to set: polling faster than they allow earns a
  /// `slow_down`, and ignoring that escalates to a hard failure — so the
  /// backoff they hand back replaces our interval rather than supplementing
  /// it.
  void _schedulePoll(DeviceCodeGrant grant, Duration interval) {
    _poller = Timer(interval, () async {
      try {
        final result = await deviceFlow.poll(grant.deviceCode);
        switch (result.state) {
          case DevicePollState.granted:
            token = result.token;
            await credentials.write(
              CredentialStore.githubTokenRef,
              result.token!,
            );
            this.grant = null;
            _set(GithubAuthStatus.signedIn);
          case DevicePollState.pending:
            _schedulePoll(grant, interval);
          case DevicePollState.slowDown:
            _schedulePoll(grant, result.interval ?? interval * 2);
          case DevicePollState.expired:
            errorMessage = 'The code expired. Start again.';
            _set(GithubAuthStatus.failed);
          case DevicePollState.denied:
            errorMessage = 'Access was declined on GitHub.';
            _set(GithubAuthStatus.failed);
        }
      } on GithubAuthException catch (error) {
        // GitHub answered and said no. That is final.
        errorMessage = error.toString();
        _set(GithubAuthStatus.failed);
      } catch (error) {
        // A transport failure — connection abort, DNS blip, signal lost.
        // Over a fifteen-minute polling window on a phone this is ordinary,
        // not exceptional, and abandoning sign-in over one dropped request
        // would make the flow unusable on a moving train. Keep polling until
        // the code itself expires.
        if (_expiresAt != null && DateTime.now().isAfter(_expiresAt!)) {
          errorMessage = 'The code expired. Start again.';
          _set(GithubAuthStatus.failed);
        } else {
          _schedulePoll(grant, interval);
        }
      }
    });
  }

  Future<void> signOut() async {
    _poller?.cancel();
    await credentials.delete(CredentialStore.githubTokenRef);
    token = null;
    grant = null;
    errorMessage = null;
    _set(GithubAuthStatus.signedOut);
  }

  void cancel() {
    _poller?.cancel();
    grant = null;
    errorMessage = null;
    _set(GithubAuthStatus.signedOut);
  }

  void _set(GithubAuthStatus next) {
    status = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }
}
