import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:mobilecode/features/voice/voice_catalog.dart';
import 'package:mobilecode/features/voice/voice_id.dart';

class VoiceServiceException implements Exception {
  VoiceServiceException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Talks to an NVIDIA Cloud Function speech endpoint.
///
/// The invocation host speaks plain REST — `GET /v1/audio/list_voices` and a
/// multipart `POST /v1/audio/synthesize` — not the gRPC that Riva's own
/// clients use. That matters here: it means no generated protobufs and no
/// native dependency, so the phone can call it directly.
class NvcfVoiceClient {
  NvcfVoiceClient({
    required String baseUrl,
    required this.apiKey,
    http.Client? client,
  })  : baseUrl = _normalise(baseUrl),
        _client = client ?? http.Client();

  final String baseUrl;
  final String apiKey;
  final http.Client _client;

  static const _timeout = Duration(seconds: 45);

  static String _normalise(String url) {
    var value = url.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  Map<String, String> get _authHeader => {'Authorization': 'Bearer $apiKey'};

  /// Every voice the endpoint offers, grouped by speaker.
  Future<VoiceCatalog> listVoices() async {
    final uri = Uri.parse('$baseUrl/v1/audio/list_voices');

    late final http.Response response;
    try {
      response = await _client.get(uri, headers: _authHeader).timeout(_timeout);
    } catch (error) {
      throw VoiceServiceException('Could not reach the voice endpoint: $error');
    }

    _throwOnFailure(response, 'list voices');

    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw VoiceServiceException(
        'The endpoint answered with something that is not JSON.',
      );
    }

    final names = parseVoiceNames(decoded);
    if (names.isEmpty) {
      throw VoiceServiceException(
        'The endpoint returned no voices. Check that this function is a TTS '
        'model rather than an ASR one.',
      );
    }
    return VoiceCatalog.fromNames(names);
  }

  /// Renders [text] and returns playable WAV bytes.
  ///
  /// [sampleRateHz] defaults to the voice's own render rate. The requested
  /// rate is also written into the WAV header, so the two must agree — see
  /// [VoiceId.nativeSampleRateHz] for why asking for anything else is a
  /// gamble on the server resampling.
  Future<Uint8List> synthesize({
    required String text,
    required VoiceId voice,
    String? languageCode,
    int? sampleRateHz,
  }) async {
    final rate = sampleRateHz ?? voice.nativeSampleRateHz;
    final uri = Uri.parse('$baseUrl/v1/audio/synthesize');
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(_authHeader)
      ..fields['text'] = text
      ..fields['language'] = languageCode ?? voice.languageCode
      ..fields['voice'] = voice.name
      ..fields['encoding'] = 'LINEAR_PCM'
      ..fields['sample_rate_hz'] = '$rate';

    late final http.Response response;
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      response = await http.Response.fromStream(streamed);
    } catch (error) {
      throw VoiceServiceException('Could not reach the voice endpoint: $error');
    }

    _throwOnFailure(response, 'synthesize speech');

    if (response.bodyBytes.isEmpty) {
      throw VoiceServiceException('The endpoint returned no audio.');
    }
    return wrapPcmAsWav(response.bodyBytes, sampleRateHz: rate);
  }

  void _throwOnFailure(http.Response response, String action) {
    if (response.statusCode == 200) return;

    // NVCF queues long-running functions and answers 202 with a request id to
    // poll. Speech functions answer synchronously, so a 202 here means this
    // endpoint is configured differently than expected — say so plainly
    // rather than returning an empty clip.
    if (response.statusCode == 202) {
      throw VoiceServiceException(
        'The endpoint queued the request instead of answering. This client '
        'only handles synchronous speech functions.',
        statusCode: 202,
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw VoiceServiceException(
        'The API key was rejected. Check it has not expired or been rotated.',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode == 429) {
      throw VoiceServiceException(
        'Rate limited — the free tier allows 40 requests a minute.',
        statusCode: 429,
      );
    }

    final detail = response.body.trim();
    throw VoiceServiceException(
      'Could not $action (HTTP ${response.statusCode})'
      '${detail.isEmpty ? '' : ': ${_truncate(detail)}'}',
      statusCode: response.statusCode,
    );
  }

  static String _truncate(String value) =>
      value.length <= 200 ? value : '${value.substring(0, 200)}…';

  void close() => _client.close();
}

/// Puts a RIFF/WAVE header on raw PCM so a player will accept it.
///
/// `encoding=LINEAR_PCM` returns headerless samples. Handing those to any
/// audio player produces silence or a format error, which reads as "the voice
/// is broken" rather than "the bytes need 44 more at the front". If the
/// endpoint ever starts returning a real WAV, the header is detected and the
/// bytes pass through untouched.
Uint8List wrapPcmAsWav(
  Uint8List pcm, {
  int sampleRateHz = 44100,
  int channels = 1,
  int bitsPerSample = 16,
}) {
  if (_isRiffWave(pcm)) return pcm;

  final byteRate = sampleRateHz * channels * (bitsPerSample ~/ 8);
  final blockAlign = channels * (bitsPerSample ~/ 8);
  final header = BytesBuilder();

  void ascii(String value) => header.add(ascii2bytes(value));
  void u32(int value) => header.add(
      Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little));
  void u16(int value) => header.add(
      Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little));

  ascii('RIFF');
  u32(36 + pcm.lengthInBytes);
  ascii('WAVE');
  ascii('fmt ');
  u32(16); // PCM subchunk size
  u16(1); // PCM, uncompressed
  u16(channels);
  u32(sampleRateHz);
  u32(byteRate);
  u16(blockAlign);
  u16(bitsPerSample);
  ascii('data');
  u32(pcm.lengthInBytes);

  return Uint8List.fromList([...header.takeBytes(), ...pcm]);
}

Uint8List ascii2bytes(String value) =>
    Uint8List.fromList(value.codeUnits);

bool _isRiffWave(Uint8List bytes) {
  if (bytes.length < 12) return false;
  return bytes[0] == 0x52 && // R
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x46 && // F
      bytes[8] == 0x57 && // W
      bytes[9] == 0x41 && // A
      bytes[10] == 0x56 && // V
      bytes[11] == 0x45; // E
}
