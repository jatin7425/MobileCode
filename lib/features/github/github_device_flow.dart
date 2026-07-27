import 'dart:convert';

import 'package:http/http.dart' as http;

/// The code the user types into github.com to authorise this device.
class DeviceCodeGrant {
  const DeviceCodeGrant({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.interval,
    required this.expiresIn,
  });

  /// Secret half, sent when polling. Never shown to the user.
  final String deviceCode;

  /// Short code the user types, e.g. `WDJB-MJHT`.
  final String userCode;

  /// Where they type it, normally https://github.com/login/device.
  final String verificationUri;

  /// Minimum seconds between polls, per GitHub.
  final Duration interval;

  final Duration expiresIn;

  factory DeviceCodeGrant.fromJson(Map<String, dynamic> json) =>
      DeviceCodeGrant(
        deviceCode: json['device_code'] as String,
        userCode: json['user_code'] as String,
        verificationUri: json['verification_uri'] as String,
        interval: Duration(seconds: (json['interval'] as num?)?.toInt() ?? 5),
        expiresIn:
            Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 900),
      );
}

/// Where a poll attempt got to.
enum DevicePollState {
  /// The user has not finished authorising yet. Keep polling.
  pending,

  /// GitHub says we are polling too fast; back off and keep going.
  slowDown,

  /// Succeeded — [DevicePollResult.token] is set.
  granted,

  /// The code expired before the user finished. Start over.
  expired,

  /// The user declined.
  denied,
}

class DevicePollResult {
  const DevicePollResult(this.state, {this.token, this.interval});

  final DevicePollState state;
  final String? token;

  /// New minimum poll interval, when GitHub asked us to slow down.
  final Duration? interval;
}

class GithubAuthException implements Exception {
  const GithubAuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// GitHub's OAuth device flow.
///
/// This is the right flow for a phone. The alternative — the web redirect
/// flow — needs a client secret to exchange the code, and there is nowhere on
/// a device to keep a secret that stays secret. Device flow needs no secret
/// and no redirect URI handling: the user reads a short code off the screen
/// and types it into github.com, and we poll until they are done.
class GithubDeviceFlow {
  GithubDeviceFlow({
    required this.clientId,
    http.Client? httpClient,
    // `codespace` is needed to list and start Codespaces; `repo` covers
    // private repositories.
    this.scopes = const ['repo', 'codespace', 'read:user'],
  }) : _http = httpClient ?? http.Client();

  /// Client id of a GitHub OAuth App with device flow enabled. Supplied at
  /// build time; see README for registering one.
  final String clientId;

  final List<String> scopes;
  final http.Client _http;

  static const _codeUrl = 'https://github.com/login/device/code';
  static const _tokenUrl = 'https://github.com/login/oauth/access_token';
  static const _grantType = 'urn:ietf:params:oauth:grant-type:device_code';

  bool get isConfigured => clientId.isNotEmpty;

  Future<DeviceCodeGrant> requestCode() async {
    if (!isConfigured) {
      throw const GithubAuthException(
        'No GitHub client id was built into this app. See the README for '
        'registering an OAuth App and passing GITHUB_CLIENT_ID.',
      );
    }

    final response = await _http.post(
      Uri.parse(_codeUrl),
      headers: const {'Accept': 'application/json'},
      body: {'client_id': clientId, 'scope': scopes.join(' ')},
    );

    final json = _decode(response.body);
    if (response.statusCode != 200 || json['device_code'] == null) {
      throw GithubAuthException(
        'GitHub refused to start sign-in: ${json['error'] ?? response.statusCode}',
      );
    }
    return DeviceCodeGrant.fromJson(json);
  }

  /// Asks once whether the user has finished authorising.
  ///
  /// Deliberately a single attempt rather than a built-in loop, so the caller
  /// owns the timing and can surface progress, honour a cancel, and apply the
  /// backoff GitHub asks for.
  Future<DevicePollResult> poll(String deviceCode) async {
    final response = await _http.post(
      Uri.parse(_tokenUrl),
      headers: const {'Accept': 'application/json'},
      body: {
        'client_id': clientId,
        'device_code': deviceCode,
        'grant_type': _grantType,
      },
    );

    final json = _decode(response.body);

    final token = json['access_token'] as String?;
    if (token != null) {
      return DevicePollResult(DevicePollState.granted, token: token);
    }

    switch (json['error']) {
      case 'authorization_pending':
        return const DevicePollResult(DevicePollState.pending);
      case 'slow_down':
        return DevicePollResult(
          DevicePollState.slowDown,
          interval: Duration(
            seconds: (json['interval'] as num?)?.toInt() ?? 10,
          ),
        );
      case 'expired_token':
        return const DevicePollResult(DevicePollState.expired);
      case 'access_denied':
        return const DevicePollResult(DevicePollState.denied);
      default:
        throw GithubAuthException(
          'GitHub sign-in failed: ${json['error_description'] ?? json['error'] ?? 'unknown error'}',
        );
    }
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      // GitHub returns HTML for some failures (rate limiting, outages).
      return const {};
    }
  }

  void dispose() => _http.close();
}
