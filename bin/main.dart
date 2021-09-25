import 'dart:io';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:uri/uri.dart';
import 'package:dotenv/dotenv.dart' as dotenv;


void addCORSHeaders(HttpRequest request) {
  Uri? _uri = Uri.tryParse(request.headers['referer']?.singleOrNull ?? '*');
  request.response.headers
    ..add(
      'Access-Control-Allow-Origin',
      (_uri != null && (const [ 'http', 'https', ]).contains(_uri.scheme) && _uri.host != '')
        ? _uri.origin
        : '*',
    )
    ..add('Access-Control-Allow-Headers', 'authorization,*')
    ..add('Access-Control-Allow-Credentials', 'true');
}

void main(List<String> arguments) async {
  if (File.fromUri(Uri.file('.env')).existsSync())
    dotenv.load();

  final InternetAddress localIp = InternetAddress.tryParse(dotenv.env['LOCAL_BIND_IP'] ?? '') ?? InternetAddress.loopbackIPv4;
  final int localPort = int.tryParse(dotenv.env['LOCAL_PORT'] ?? '') ?? 8080;
  final String serverScheme = dotenv.env['SERVER_SCHEME'] ?? 'https';
  final String serverHost = dotenv.env['SERVER_HOST'] ?? 'example.com';
  final int serverPort = int.tryParse(dotenv.env['SERVER_PORT'] ?? (serverScheme == 'https' ? '443' : '')) ?? 80;
  final String? serverUsername = dotenv.env['SERVER_USERNAME'];
  final String? serverPassword = dotenv.env['SERVER_PASSWORD'];
  final String? serverBasicAuth = (serverUsername != null && serverPassword != null)
    ? 'Basic ${base64Encode(utf8.encode('$serverUsername:$serverPassword'))}'
    : null;
  final String serverBaseUrl = '$serverScheme://$serverHost${![ 'http', 'https', ].contains(serverScheme) ? serverPort : ''}';
  final String? localUsername = dotenv.env['LOCAL_USERNAME'];
  final String? localPassword = dotenv.env['LOCAL_PASSWORD'];
  final String? localBasicAuth = (localUsername != null && localPassword != null)
    ? 'Basic ${base64Encode(utf8.encode('$localUsername:$localPassword'))}'
    : null;
  final String localBaseUrl = 'http://${localIp.host}:$localPort';

  stdout.write('Starting mirror server $localBaseUrl -> $serverBaseUrl');
  if (localBasicAuth != null)
    stdout.write(' [Local auth]');
  if (serverBasicAuth != null)
    stdout.write(' [Remote auth auto-fill]');

  late final HttpServer server;
  try {
    server = await HttpServer.bind(localIp, localPort);
  } catch(error) {
    stdout.writeln(' [Error]');
    stderr.writeln('Error unable to bind server.');
    return;
  }
  stdout.writeln(' [Done]');
  final HttpClient client = HttpClient();


  server.listen((HttpRequest request) {
    addCORSHeaders(request);
    final HttpResponse response = request.response;

    if (localBasicAuth != null) {
      if (request.method == 'OPTIONS') {
        response
          ..statusCode = HttpStatus.ok
          ..close();
        return;
      }

      final String? _userAuth = request.headers['authorization']?.singleOrNull;
      if (_userAuth == null || _userAuth != localBasicAuth) {
        response
          ..statusCode = HttpStatus.unauthorized
          ..headers.add('WWW-Authenticate', 'Basic realm=Protected')
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
      .then((HttpClientRequest proxyRequest) {
        if (serverBasicAuth != null)
          proxyRequest.headers.add('Authorization', serverBasicAuth);
        request.headers.forEach((name, values) {
          if (![
            'host',
          ].contains(name))
            if (name == 'referer')
              proxyRequest.headers.add(
                name,
                values.map(
                  (String value) => value.replaceAll(localBaseUrl, serverBaseUrl),
                ),
              );
            else
              proxyRequest.headers.add(name, values);
        });
        return proxyRequest.close();
      })
      .then((HttpClientResponse proxyResponse) async {
        stdout.write(' [${proxyResponse.statusCode}]');
        proxyResponse.headers.forEach((name, values) {
          if (![
            'connection',
            'content-length',
            'content-encoding',
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
