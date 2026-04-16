import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'auth.dart';
import 'logging.dart';

class AscApiException implements Exception {
  final int statusCode;
  final String method;
  final String path;
  final String body;

  AscApiException(this.statusCode, this.method, this.path, this.body);

  @override
  String toString() => 'AscApiException $statusCode on $method $path: $body';
}

class AscClient {
  static const String baseUrl = 'https://api.appstoreconnect.apple.com';
  final AuthService auth;
  final LoggingService _log = LoggingService.instance;
  final http.Client _http = http.Client();

  AscClient(this.auth);

  void close() => _http.close();

  Future<Map<String, String>> _authHeaders() async {
    final token = await auth.getToken();
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
  }

  Uri _resolve(String path, [Map<String, dynamic>? query]) {
    final uri = Uri.parse(path.startsWith('http') ? path : '$baseUrl$path');
    if (query == null || query.isEmpty) return uri;
    final qp = <String, String>{};
    query.forEach((k, v) {
      if (v == null) return;
      if (v is Iterable) {
        qp[k] = v.map((e) => e.toString()).join(',');
      } else {
        qp[k] = v.toString();
      }
    });
    return uri.replace(queryParameters: {...uri.queryParameters, ...qp});
  }

  Future<Map<String, dynamic>> getJson(String path,
      {Map<String, dynamic>? query}) async {
    final uri = _resolve(path, query);
    final headers = await _authHeaders();
    _log.debug('GET $uri', scope: 'http');
    final resp = await _http.get(uri, headers: headers);
    return _decode('GET', uri.toString(), resp);
  }

  Future<List<Map<String, dynamic>>> getAllData(String path,
      {Map<String, dynamic>? query, int limit = 200}) async {
    final results = <Map<String, dynamic>>[];
    String? next;
    Map<String, dynamic> json = await getJson(path, query: {
      ...?query,
      'limit': limit,
    });
    while (true) {
      final data = json['data'];
      if (data is List) {
        for (final e in data) {
          if (e is Map<String, dynamic>) results.add(e);
        }
      }
      next = (json['links'] is Map)
          ? (json['links']['next'] as String?)
          : null;
      if (next == null) break;
      json = await getJson(next);
    }
    return results;
  }

  Future<Map<String, dynamic>> postJson(
      String path, Map<String, dynamic> body) async {
    final uri = _resolve(path);
    final headers = await _authHeaders();
    _log.debug('POST $uri', scope: 'http');
    final resp =
        await _http.post(uri, headers: headers, body: jsonEncode(body));
    return _decode('POST', uri.toString(), resp);
  }

  Future<Map<String, dynamic>> patchJson(
      String path, Map<String, dynamic> body) async {
    final uri = _resolve(path);
    final headers = await _authHeaders();
    _log.debug('PATCH $uri', scope: 'http');
    final resp =
        await _http.patch(uri, headers: headers, body: jsonEncode(body));
    return _decode('PATCH', uri.toString(), resp);
  }

  Future<void> delete(String path) async {
    final uri = _resolve(path);
    final headers = await _authHeaders();
    _log.debug('DELETE $uri', scope: 'http');
    final resp = await _http.delete(uri, headers: headers);
    if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    throw AscApiException(resp.statusCode, 'DELETE', uri.toString(), resp.body);
  }

  Future<void> uploadBinary({
    required String method,
    required String url,
    required Map<String, String> headers,
    required Uint8List bytes,
  }) async {
    final uri = Uri.parse(url);
    final client = HttpClient();
    try {
      final req = await client.openUrl(method.toUpperCase(), uri);
      req.followRedirects = false;
      req.contentLength = bytes.length;
      headers.forEach((k, v) {
        if (k.toLowerCase() == 'content-length') return;
        req.headers.set(k, v);
      });
      _log.debug(
          '$method (upload) $uri bytes=${bytes.length} hdrs=[${headers.keys.join(',')}]',
          scope: 'http');
      req.add(bytes);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw AscApiException(resp.statusCode, method, url, body);
      }
    } finally {
      client.close(force: false);
    }
  }

  Map<String, dynamic> _decode(String method, String url, http.Response resp) {
    final status = resp.statusCode;
    if (status == HttpStatus.noContent || resp.body.isEmpty) {
      if (status >= 200 && status < 300) return const {};
      throw AscApiException(status, method, url, '');
    }
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(resp.body) as Map<String, dynamic>;
    } on FormatException {
      throw AscApiException(status, method, url, resp.body);
    }
    if (status < 200 || status >= 300) {
      throw AscApiException(status, method, url, resp.body);
    }
    return parsed;
  }
}
