import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:mobilecode/features/github/github_models.dart';

class GithubApiException implements Exception {
  const GithubApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Read access to the user's GitHub account.
///
/// Scope is deliberately narrow: listing and reading. Code never moves through
/// here — cloning, committing, and pushing happen on the host over SSH, which
/// already has credentials and disk. The phone is not a git client.
class GithubClient {
  GithubClient({required this.token, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final String token;
  final http.Client _http;

  static const _base = 'https://api.github.com';

  Map<String, String> get _headers => {
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  /// The signed-in user's login.
  Future<String> currentUser() async {
    final json = await _get('/user');
    return (json as Map<String, dynamic>)['login'] as String;
  }

  /// Repositories the user can push to, most recently pushed first.
  Future<List<GithubRepo>> repositories({int perPage = 30}) async {
    final json = await _get(
      '/user/repos?sort=pushed&direction=desc&per_page=$perPage',
    );
    return (json as List)
        .cast<Map<String, dynamic>>()
        .map(GithubRepo.fromJson)
        .toList();
  }

  Future<List<GithubPullRequest>> pullRequests(
    String fullName, {
    String state = 'open',
    int perPage = 30,
  }) async {
    final json = await _get(
      '/repos/$fullName/pulls?state=$state&per_page=$perPage',
    );
    return (json as List)
        .cast<Map<String, dynamic>>()
        .map(GithubPullRequest.fromJson)
        .toList();
  }

  Future<Object?> _get(String path) async {
    final http.Response response;
    try {
      response = await _http.get(Uri.parse('$_base$path'), headers: _headers);
    } catch (error) {
      throw GithubApiException('Could not reach GitHub: $error');
    }

    if (response.statusCode == 401) {
      throw const GithubApiException(
        'GitHub rejected the saved token. Sign in again.',
        statusCode: 401,
      );
    }
    if (response.statusCode == 403 &&
        response.headers['x-ratelimit-remaining'] == '0') {
      throw const GithubApiException(
        'GitHub rate limit reached. Try again shortly.',
        statusCode: 403,
      );
    }
    if (response.statusCode >= 400) {
      throw GithubApiException(
        'GitHub returned ${response.statusCode} for $path.',
        statusCode: response.statusCode,
      );
    }

    return jsonDecode(response.body);
  }

  void dispose() => _http.close();
}
