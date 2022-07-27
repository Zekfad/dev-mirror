import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dotenv/dotenv.dart' as dotenv;
import 'package:uri/uri.dart';


final List<String> trustedCert = [
  [72, 80, 78, 151, 76, 13, 172, 91, 92, 212, 118, 200, 32, 34, 116, 178, 76, 140, 113, 114], // DST Root CA X3
].map(String.fromCharCodes).toList();

void addCORSHeaders(HttpRequest request) {
  final _uri = Uri.tryParse(request.headers['referer']?.singleOrNull ?? '*');
  request.response.headers
    ..add(
      'Access-Control-Allow-Origin',
      (_uri != null && (const [ 'http', 'https', ]).contains(_uri.scheme) && _uri.host != '')
        ? _uri.origin
        : '*',
    )
    ..add(
      'Access-Control-Allow-Methods',
      request.headers['access-control-request-method']?.join(',') ?? '*',
    )
    ..add(
      'Access-Control-Allow-Headers',
      request.headers['access-control-request-headers']?.join(',') ?? 'authorization,*',
    )
    ..add('Access-Control-Allow-Credentials', 'true');
}

void main(List<String> arguments) async {
  final dotEnvFile = arguments.firstOrNull ?? '.env';
  if (File.fromUri(Uri.file(dotEnvFile)).existsSync())
    dotenv.load(dotEnvFile);

  // Local server
  final localIp = InternetAddress.tryParse(dotenv.env['LOCAL_BIND_IP'] ?? '') ?? InternetAddress.loopbackIPv4;
  final localPort = int.tryParse(dotenv.env['LOCAL_PORT'] ?? '') ?? 8080;
  // Local auth
  final localUsername = dotenv.env['LOCAL_USERNAME'];
  final localPassword = dotenv.env['LOCAL_PASSWORD'];
  final localBasicAuth = (localUsername != null && localPassword != null)
    ? 'Basic ${base64Encode(utf8.encode('$localUsername:$localPassword'))}'
    : null;
  final localBaseUrl = 'http://${localIp.host}:$localPort';

  // Remote server
  final serverScheme = dotenv.env['SERVER_SCHEME'] ?? 'https';
  final serverHost = dotenv.env['SERVER_HOST'] ?? 'example.com';
  final serverPort = int.tryParse(dotenv.env['SERVER_PORT'] ?? (serverScheme == 'https' ? '443' : '')) ?? 80;
  // Server auth
  final serverUsername = dotenv.env['SERVER_USERNAME'];
  final serverPassword = dotenv.env['SERVER_PASSWORD'];
  final serverBasicAuth = (serverUsername != null && serverPassword != null)
    ? 'Basic ${base64Encode(utf8.encode('$serverUsername:$serverPassword'))}'
    : null;
  final serverBaseUrl = '$serverScheme://$serverHost${![ 'http', 'https', ].contains(serverScheme) ? serverPort : ''}';

  final httpProxy = Uri.tryParse(dotenv.env['HTTP_PROXY'] ?? '::Not valid URI::');
  final match = httpProxy != null
    ? RegExp(r'^(?<username>.+?):(?<password>.+?)$')
      .firstMatch(httpProxy.userInfo)
    : null;
  final proxyUsername = match?.namedGroup('username');
  final proxyPassword = match?.namedGroup('password');
  final httpProxyCredentials = (proxyUsername != null && proxyPassword != null)
    ? HttpClientBasicCredentials(proxyUsername, proxyPassword)
    : null;

  stdout.write('Starting mirror server $localBaseUrl -> $serverBaseUrl');
  if (localBasicAuth != null)
    stdout.write(' [Local auth]');
  if (serverBasicAuth != null)
    stdout.write(' [Remote auth auto-fill]');
  if (httpProxy != null) {
    stdout.write(' [Through HTTP proxy]');
    if (httpProxy.scheme != 'http') {
      stdout.writeln(' [Error]');
      stderr.writeln('Proxy URI must be valid.');
      return;
    }
  }

  late final HttpServer server;
  try {
    server = await HttpServer.bind(localIp, localPort);
  } catch(error) {
    stdout.writeln(' [Error]');
    stderr
      ..writeln('Error unable to bind server:')
      ..writeln(error);
    return;
  }
  stdout.writeln(' [Done]');
  final client = HttpClient()
    ..badCertificateCallback = (cert, host, port) =>
      trustedCert.contains(String.fromCharCodes(cert.sha1));

  // HTTP proxy
  if (httpProxy != null) {
    if (httpProxyCredentials != null) {
      client.addProxyCredentials(
        httpProxy.host,
        httpProxy.port,
        'Basic',
        httpProxyCredentials,
      );
    }
    client.findProxy = (uri) => 'PROXY ${httpProxy.host}:${httpProxy.port}';
  }

  server.listen((request) {
    addCORSHeaders(request);
    final response = request.response;

    // preflight
    if (
      request.method == 'OPTIONS' &&
      request.headers[HttpHeaders.accessControlRequestMethodHeader] != null
    ) {
      response
        ..contentLength = 0
        ..statusCode = HttpStatus.ok
        ..close();
      return;
    }

    if (localBasicAuth != null) {
      final _userAuth = request.headers[HttpHeaders.authorizationHeader]?.singleOrNull;
      if (_userAuth == null || _userAuth != localBasicAuth) {
        response
          ..statusCode = HttpStatus.unauthorized
          ..headers.add(HttpHeaders.wwwAuthenticateHeader, 'Basic realm=Protected')
          ..headers.contentType = ContentType.text
          ..write('PROXY///ERROR///UNAUTHORIZED')
          ..close();
        return;
      }
    }

    final targetUri = (UriBuilder
      .fromUri(request.uri)
      ..scheme = serverScheme
      ..host = serverHost
      ..port = serverPort
    ).build();

    stdout.write('Proxy: ${request.method} $targetUri');

    (client
      ..userAgent = request.headers['user-agent']?.singleOrNull)
      .openUrl(request.method, targetUri)
      .then((proxyRequest) async {
        if (serverBasicAuth != null)
          proxyRequest.headers.add(HttpHeaders.authorizationHeader, serverBasicAuth);
        request.headers.forEach((name, values) {
          if (![
            // Headers to skip
            HttpHeaders.hostHeader,
          ].contains(name)) {
            if (name == HttpHeaders.refererHeader)
              proxyRequest.headers.add(
                name,
                values.map(
                  (value) => value.replaceAll(localBaseUrl, serverBaseUrl),
                ),
              );
            else
              proxyRequest.headers.add(name, values);
          }
        });
        if (request.contentLength > 0)
          await proxyRequest.addStream(request);
        return proxyRequest.close();
      })
      .then(
        (proxyResponse) async {
          stdout.write(' [${proxyResponse.statusCode}]');
          proxyResponse.headers.forEach((name, values) {
            if (![
              HttpHeaders.connectionHeader,
              HttpHeaders.contentLengthHeader,
              HttpHeaders.contentEncodingHeader,
            ].contains(name))
              response.headers.add(name, values);
          });
          response.statusCode = proxyResponse.statusCode;
          proxyResponse
            .pipe(response)
            .then((value) => stdout.writeln(' [Done]'))
            .ignore();
        },
        onError: (dynamic error) {
          stdout.writeln(' [Error]');
          stderr.writeln('Proxy error details: $error');
          response
            ..statusCode = HttpStatus.internalServerError
            ..headers.contentType = ContentType.text
            ..writeln('PROXY///ERROR///INTERNAL')
            ..write(error)
            ..close();
        },
      );
  });
}
