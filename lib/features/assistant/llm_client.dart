import 'dart:convert';

import 'package:http/http.dart' as http;

class LlmException implements Exception {
  LlmException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Chat client for an OpenAI-compatible endpoint.
///
/// LiteLLM, Groq, Together, Ollama's compatibility layer and NVIDIA's own LLM
/// NIMs all speak this shape, so the assistant is not tied to one provider —
/// only the base URL and model name change.
class LlmClient {
  LlmClient({
    required String baseUrl,
    required this.apiKey,
    required this.model,
    http.Client? client,
  })  : baseUrl = _normalise(baseUrl),
        _client = client ?? http.Client();

  final String baseUrl;
  final String apiKey;
  final String model;
  final http.Client _client;

  static const _timeout = Duration(seconds: 40);

  static String _normalise(String url) {
    var value = url.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    // Accept both `https://host` and `https://host/v1`, since LiteLLM is
    // usually published with the version segment already attached and pasting
    // it twice is the obvious mistake.
    return value.endsWith('/v1') ? value : '$value/v1';
  }

  /// Sends [messages] and returns the assistant's raw reply text.
  ///
  /// [responseFormat] carries the mood enum when the assigned speaker has
  /// moods; the caller still validates the reply, because support for
  /// structured output varies by model and by proxy.
  Future<String> complete({
    required List<Map<String, String>> messages,
    Map<String, Object?>? responseFormat,
  }) async {
    final uri = Uri.parse('$baseUrl/chat/completions');
    final body = <String, Object?>{
      'model': model,
      'messages': messages,
      'temperature': 0.6,
      // Spoken answers are short by design; a cap keeps a runaway model from
      // producing a minute of speech and a large synthesis bill.
      'max_tokens': 300,
      'response_format': ?responseFormat,
    };

    late final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (error) {
      throw LlmException('Could not reach the model: $error');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw LlmException('The model API key was rejected.',
          statusCode: response.statusCode);
    }
    if (response.statusCode != 200) {
      throw LlmException(
        'The model returned HTTP ${response.statusCode}'
        '${response.body.isEmpty ? '' : ': ${_truncate(response.body)}'}',
        statusCode: response.statusCode,
      );
    }

    return extractReply(utf8.decode(response.bodyBytes));
  }

  static String _truncate(String value) =>
      value.length <= 200 ? value : '${value.substring(0, 200)}…';

  void close() => _client.close();
}

/// Pulls the assistant message out of a chat completion response.
///
/// Separate from the client so it can be tested without a socket, and
/// tolerant because proxies reshape these payloads: some omit `content` when
/// a refusal is present, some return the choice list empty.
String extractReply(String responseBody) {
  Object? decoded;
  try {
    decoded = jsonDecode(responseBody);
  } catch (_) {
    throw LlmException('The model did not return JSON.');
  }

  if (decoded is! Map) throw LlmException('The model returned no message.');

  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) {
    // Some gateways surface their own failures in an `error` object with a
    // 200 status, which would otherwise look like an empty answer.
    final error = decoded['error'];
    if (error is Map && error['message'] != null) {
      throw LlmException('${error['message']}');
    }
    throw LlmException('The model returned no message.');
  }

  final message = (choices.first as Map)['message'];
  if (message is! Map) throw LlmException('The model returned no message.');

  final content = message['content'];
  if (content is String && content.trim().isNotEmpty) return content.trim();

  final refusal = message['refusal'];
  if (refusal is String && refusal.trim().isNotEmpty) return refusal.trim();

  throw LlmException('The model returned an empty message.');
}
