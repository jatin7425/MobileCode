import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:mobilecode/features/codespaces/codespace.dart';
import 'package:mobilecode/features/github/github_client.dart';

/// Lists and starts the user's Codespaces.
///
/// Needs a token with the `codespace` scope, which is why the device flow
/// requests it alongside `repo`.
class CodespacesClient {
  CodespacesClient({required this.token, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final String token;
  final http.Client _http;

  static const _base = 'https://api.github.com';

  Map<String, String> get _headers => {
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  Future<List<Codespace>> list() async {
    final response = await _send('GET', '/user/codespaces');
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return (json['codespaces'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(Codespace.fromJson)
        .toList();
  }

  /// Asks GitHub to resume a stopped Codespace.
  ///
  /// Returns immediately with the Codespace in a starting state; booting takes
  /// tens of seconds, so callers should poll [list] rather than assume the
  /// machine is reachable when this completes.
  Future<Codespace> start(String name) async {
    final response = await _send('POST', '/user/codespaces/$name/start');
    return Codespace.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<http.Response> _send(String method, String path) async {
    final uri = Uri.parse('$_base$path');
    final http.Response response;

    try {
      response = switch (method) {
        'POST' => await _http.post(uri, headers: _headers),
        _ => await _http.get(uri, headers: _headers),
      };
    } catch (error) {
      throw GithubApiException('Could not reach GitHub: $error');
    }

    if (response.statusCode == 401) {
      throw const GithubApiException(
        'GitHub rejected the saved token. Sign in again.',
        statusCode: 401,
      );
    }
    if (response.statusCode == 403) {
      throw const GithubApiException(
        'This token cannot manage Codespaces. Sign in again so the app can '
        'request the codespace scope.',
        statusCode: 403,
      );
    }
    if (response.statusCode >= 400) {
      throw GithubApiException(
        'GitHub returned ${response.statusCode} for $path.',
        statusCode: response.statusCode,
      );
    }

    return response;
  }

  void dispose() => _http.close();
}
