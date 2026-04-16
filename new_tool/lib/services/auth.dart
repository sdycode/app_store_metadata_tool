import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

import '../models/config.dart';
import 'logging.dart';

class AuthService {
  final AppStoreConnectCreds creds;
  final File p8Key;
  final LoggingService _log = LoggingService.instance;

  String? _cachedToken;
  DateTime? _cachedExp;

  AuthService({required this.creds, required this.p8Key});

  Future<String> getToken() async {
    final now = DateTime.now().toUtc();
    if (_cachedToken != null &&
        _cachedExp != null &&
        _cachedExp!.isAfter(now.add(const Duration(minutes: 1)))) {
      return _cachedToken!;
    }

    final pem = await p8Key.readAsString();
    final exp = now.add(const Duration(minutes: 18));
    final jwt = JWT(
      {
        'iss': creds.issuerId,
        'iat': now.millisecondsSinceEpoch ~/ 1000,
        'exp': exp.millisecondsSinceEpoch ~/ 1000,
        'aud': 'appstoreconnect-v1',
      },
      header: {
        'alg': 'ES256',
        'kid': creds.keyId,
        'typ': 'JWT',
      },
    );
    final token = jwt.sign(
      ECPrivateKey(pem),
      algorithm: JWTAlgorithm.ES256,
    );
    _cachedToken = token;
    _cachedExp = exp;
    _log.debug('JWT minted (kid=${creds.keyId}, exp=${exp.toIso8601String()})',
        scope: 'auth');
    return token;
  }

  void invalidate() {
    _cachedToken = null;
    _cachedExp = null;
  }
}
