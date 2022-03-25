import 'dart:io';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:uri/uri.dart';
import 'package:dotenv/dotenv.dart' as dotenv;


final List<String> trustedCert = [
  [72, 80, 78, 151, 76, 13, 172, 91, 92, 212, 118, 200, 32, 34, 116, 178, 76, 140, 113, 114], // DST Root CA X3
].map((e) => String.fromCharCodes(e)).toList();

void addCORSHeaders(HttpRequest request) {
  Uri? _uri = Uri.tryParse(request.headers['referer']?.singleOrNull ?? '*');
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
      request.headers['access-control-request-headers']?.join(',') ?? 'authorization,*'
    )
    ..add('Access-Control-Allow-Credentials', 'true');
}

void main(List<String> arguments) async {
  String dotEnvFile = arguments.firstOrNull ?? '.env';
  if (File.fromUri(Uri.file(dotEnvFile)).existsSync())
    dotenv.load(dotEnvFile);

  // Local server
  final InternetAddress localIp = InternetAddress.tryParse(dotenv.env['LOCAL_BIND_IP'] ?? '') ?? InternetAddress.loopbackIPv4;
  final int localPort = int.tryParse(dotenv.env['LOCAL_PORT'] ?? '') ?? 8080;
  // Local auth
  final String? localUsername = dotenv.env['LOCAL_USERNAME'];
  final String? localPassword = dotenv.env['LOCAL_PASSWORD'];
  final String? localBasicAuth = (localUsername != null && localPassword != null)
    ? 'Basic ${base64Encode(utf8.encode('$localUsername:$localPassword'))}'
    : null;
  final String localBaseUrl = 'http://${localIp.host}:$localPort';

  // Remote server
  final String serverScheme = dotenv.env['SERVER_SCHEME'] ?? 'https';
  final String serverHost = dotenv.env['SERVER_HOST'] ?? 'example.com';
  final int serverPort = int.tryParse(dotenv.env['SERVER_PORT'] ?? (serverScheme == 'https' ? '443' : '')) ?? 80;
  // Server auth
  final String? serverUsername = dotenv.env['SERVER_USERNAME'];
  final String? serverPassword = dotenv.env['SERVER_PASSWORD'];
  final String? serverBasicAuth = (serverUsername != null && serverPassword != null)
    ? 'Basic ${base64Encode(utf8.encode('$serverUsername:$serverPassword'))}'
    : null;
  final String serverBaseUrl = '$serverScheme://$serverHost${![ 'http', 'https', ].contains(serverScheme) ? serverPort : ''}';

  final Uri? httpProxy = Uri.tryParse(dotenv.env['HTTP_PROXY'] ?? '::Not valid URI::');
  final RegExpMatch? match = httpProxy != null
    ? RegExp(r'^(?<username>.+?):(?<password>.+?)$')
      .firstMatch(httpProxy.userInfo)
    : null;
  final String? proxyUsername = match?.namedGroup('username');
  final String? proxyPassword = match?.namedGroup('password');
  final HttpClientBasicCredentials? httpProxyCredentials = (proxyUsername != null && proxyPassword != null)
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
    stderr.writeln('Error unable to bind server:');
    stderr.writeln(error);
    return;
  }
  stdout.writeln(' [Done]');
  final HttpClient client = HttpClient()
    ..badCertificateCallback = (X509Certificate cert, String host, int port) {
      return trustedCert.contains(String.fromCharCodes(cert.sha1));
    };

  // HTTP proxy
  if (httpProxy != null) {
    if (httpProxyCredentials != null) {
      client.addProxyCredentials(
        httpProxy.host,
        httpProxy.port,
        'Basic',
        httpProxyCredentials
      );
    }
    client.findProxy = (uri) => 'PROXY ${httpProxy.host}:${httpProxy.port}';
  }

  server.listen((HttpRequest request) {
    addCORSHeaders(request);
    final HttpResponse response = request.response;

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
      final String? _userAuth = request.headers[HttpHeaders.authorizationHeader]?.singleOrNull;
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

    final Uri targetUri = (UriBuilder
      .fromUri(request.uri)
      ..scheme = serverScheme
      ..host = serverHost
      ..port = serverPort
    ).build();

    stdout.write('Proxy: ${request.method} $targetUri');

    (client
      ..userAgent = request.headers['user-agent']?.singleOrNull)
      .openUrl(request.method, targetUri)
      .then((HttpClientRequest proxyRequest) async {
        if (serverBasicAuth != null)
          proxyRequest.headers.add(HttpHeaders.authorizationHeader, serverBasicAuth);
        request.headers.forEach((String name, List<String> values) {
          if (![
            // Headers to skip
            HttpHeaders.hostHeader,
          ].contains(name)) {
            if (name == HttpHeaders.refererHeader)
              proxyRequest.headers.add(
                name,
                values.map(
                  (String value) => value.replaceAll(localBaseUrl, serverBaseUrl),
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
      .then((HttpClientResponse proxyResponse) async {
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
        proxyResponse.pipe(response).then((value) => stdout.writeln(' [Done]'));
      })
      .catchError((error) {
        stdout.writeln(' [Error]');
        stderr.writeln('Proxy error details: $error');
        response
          ..statusCode = HttpStatus.internalServerError
          ..headers.contentType = ContentType.text
          ..writeln('PROXY///ERROR///INTERNAL')
          ..write(error)
          ..close();
      });
  });
}
