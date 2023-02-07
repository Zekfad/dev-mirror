import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dotenv/dotenv.dart' as dotenv;
import 'package:uri/uri.dart';


/// Invalid string URI.
const _invalidUri = '::Not valid URI::';
const headersNotToForwardToRemote = [
  HttpHeaders.hostHeader,
];
const headersToSpoofBeforeForwardToRemote = [
  HttpHeaders.refererHeader,
];
const headersNotToForwardFromRemote = [
  HttpHeaders.connectionHeader,
];
const headersToSpoofBeforeForwardFromRemote = [
  HttpHeaders.locationHeader,
];


extension UriHasOrigin on Uri {
  bool get hasOrigin => (scheme == 'http' || scheme == 'https') && host != '';
}

/// List of additional root CA
final List<String> trustedRoots = [
  [72, 80, 78, 151, 76, 13, 172, 91, 92, 212, 118, 200, 32, 34, 116, 178, 76, 140, 113, 114], // DST Root CA X3
].map(String.fromCharCodes).toList();

bool secureCompare(String a, String b) {
  if(a.codeUnits.length != b.codeUnits.length)
    return false;

  var r = 0;
  for(var i = 0; i < a.codeUnits.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}

/// Returns environment variable or `.env` variable
String? getEnv(String variable) =>
  Platform.environment[variable] ?? dotenv.env[variable];

/// Adds CORS headers to [response]
void addCORSHeaders(HttpRequest request, HttpResponse response) {
  final refererUri = Uri.tryParse(
    request.headers[HttpHeaders.refererHeader]?.singleOrNull ?? _invalidUri,
  );
  response.headers
    ..add(
      HttpHeaders.accessControlAllowOriginHeader,
      (refererUri != null && refererUri.hasOrigin)
        ? refererUri.origin
        : '*',
    )
    ..add(
      HttpHeaders.accessControlAllowMethodsHeader,
      request.headers[HttpHeaders.accessControlRequestMethodHeader]?.join(',')
        ?? '*',
    )
    ..add(
      HttpHeaders.accessControlAllowHeadersHeader,
      request.headers[HttpHeaders.accessControlRequestHeadersHeader]?.join(',')
        ?? 'authorization,*',
    )
    ..add(
      HttpHeaders.accessControlAllowCredentialsHeader,
      'true',
    );
}

void main(List<String> arguments) async {
  final dotEnvFile = arguments.firstOrNull ?? '.env';
  if (File.fromUri(Uri.file(dotEnvFile)).existsSync())
    dotenv.load(dotEnvFile);

  // Local server bind settings
  final localBindIp = InternetAddress.tryParse(getEnv('LOCAL_BIND_IP') ?? '') ?? InternetAddress.loopbackIPv4;
  final localPort = int.tryParse(getEnv('LOCAL_PORT') ?? '') ?? 8080;

  // Local auth
  final localUsername = getEnv('LOCAL_USERNAME');
  final localPassword = getEnv('LOCAL_PASSWORD');
  final localBasicAuth = (localUsername == null || localPassword == null) ? null
    : 'Basic ${base64Encode(utf8.encode('$localUsername:$localPassword'))}';
  final localBaseUrl = 'http://${localBindIp.host}:$localPort';

  // Remote server
  final remoteScheme = getEnv('SERVER_SCHEME') ?? 'https';
  final remoteHost = getEnv('SERVER_HOST') ?? 'example.com';
  final remotePort = int.tryParse(getEnv('SERVER_PORT') ?? (remoteScheme == 'https' ? '443' : '')) ?? 80;

  // Remote server auth
  final remoteUsername = getEnv('SERVER_USERNAME');
  final remotePassword = getEnv('SERVER_PASSWORD');
  final remoteBasicAuth = (remoteUsername == null || remotePassword == null) ? null
    : 'Basic ${base64Encode(utf8.encode('$remoteUsername:$remotePassword'))}';
  final serverBaseUrl = '$remoteScheme://$remoteHost${![ 'http', 'https', ].contains(remoteScheme) ? remotePort : ''}';

  // HTTP proxy
  final httpProxy = Uri.tryParse(getEnv('HTTP_PROXY') ?? _invalidUri);
  final httpProxyCredentialsMatch = httpProxy == null ? null
    : RegExp(r'^(?<username>.+?):(?<password>.+?)$').firstMatch(httpProxy.userInfo);
  final httpProxyUsername = httpProxyCredentialsMatch?.namedGroup('username');
  final httpProxyPassword = httpProxyCredentialsMatch?.namedGroup('password');
  final httpProxyCredentials = (httpProxyUsername == null || httpProxyPassword == null) ? null
    : HttpClientBasicCredentials(httpProxyUsername, httpProxyPassword);

  stdout.write('Starting mirror server $localBaseUrl -> $serverBaseUrl');
  if (localBasicAuth != null)
    stdout.write(' [Local auth]');
  if (remoteBasicAuth != null)
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
    server = await HttpServer.bind(localBindIp, localPort);
  } catch(error) {
    stdout.writeln(' [Error]');
    stderr
      ..writeln('Error unable to bind server:')
      ..writeln(error);
    return;
  }
  stdout.writeln(' [Done]');

  final client = HttpClient()
    ..autoUncompress = false
    ..badCertificateCallback = (cert, host, port) =>
      trustedRoots.contains(String.fromCharCodes(cert.sha1));

  // Apply HTTP proxy
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

  var requestId = 0;

  server.listen((request) {
    requestId++;

    final response = request.response;

    addCORSHeaders(request, response);

    // Handle preflight
    if (
      request.method.toUpperCase() == 'OPTIONS' &&
      request.headers[HttpHeaders.accessControlRequestMethodHeader] != null
    ) {
      stdout.writeln('[$requestId] Preflight handled.');
      response
        ..contentLength = 0
        ..statusCode = HttpStatus.ok
        ..close();
      return;
    }

    if (localBasicAuth != null) {
      final _userAuth = request.headers[HttpHeaders.authorizationHeader]?.singleOrNull;
      if (_userAuth == null || !secureCompare(_userAuth, localBasicAuth)) {
        stdout.writeln('[$requestId] Unauthorized access denied.');
        response
          ..statusCode = HttpStatus.unauthorized
          ..headers.add(HttpHeaders.wwwAuthenticateHeader, 'Basic realm=Protected')
          ..headers.contentType = ContentType.text
          ..write('PROXY///ERROR///UNAUTHORIZED')
          ..close();
        return;
      }
    }

    final remoteUri = (UriBuilder.fromUri(request.uri)
      ..scheme = remoteScheme
      ..host = remoteHost
      ..port = remotePort
    ).build();

    stdout.writeln('[$requestId] Forwarding: ${request.method} $remoteUri');

    (client..userAgent = request.headers[HttpHeaders.userAgentHeader]?.singleOrNull)
      .openUrl(request.method, remoteUri)
      .then((requestToRemote) async {
        requestToRemote.followRedirects = false;

        // Remote server auth
        if (remoteBasicAuth != null)
          requestToRemote.headers.add(HttpHeaders.authorizationHeader, remoteBasicAuth);

        request.headers.forEach((headerName, headerValues) {
          // Filter out headers
          if (!headersNotToForwardToRemote.contains(headerName)) {
            // Spoof headers to look like from the original server
            if (headersToSpoofBeforeForwardToRemote.contains(headerName))
              requestToRemote.headers.add(
                headerName,
                headerValues.map(
                  (value) => value.replaceAll(localBaseUrl, serverBaseUrl),
                ),
              );
            else
            // Forward headers as-is
              requestToRemote.headers.add(headerName, headerValues);
          }
        });

        // If there's content pipe request body
        if (request.contentLength > 0)
          await requestToRemote.addStream(request);

        return requestToRemote.close();
      })
      .then(
        (remoteResponse) async {
          stdout.writeln('[$requestId] Remote response: ${remoteResponse.statusCode}');
          remoteResponse.headers.forEach((headerName, headerValues) {
            // Filter out headers
            if (!headersNotToForwardFromRemote.contains(headerName))
              // Spoof headers, so they'll point to mirror
              if (headersToSpoofBeforeForwardFromRemote.contains(headerName))
                response.headers.add(
                  headerName,
                  headerValues.map(
                    (value) => value.replaceAll(serverBaseUrl, localBaseUrl),
                  ),
                );
              // Add headers as-is
              else
                response.headers.add(headerName, headerValues);
          });
          response.statusCode = remoteResponse.statusCode;

          // Pipe remote response
          remoteResponse
            .pipe(response)
            .then(
              (_) => stdout.writeln('[$requestId] Forwarded.'),
              onError: (dynamic error) {
                final _error = error.toString().splitMapJoin(
                  '\n',
                  onNonMatch: (part) => '[$requestId] $part',
                );
                stderr
                  ..writeln('[$requestId] Response forwarding error:')
                  ..writeln(_error);
              },
            )
            .ignore();
        },
        onError: (dynamic error) {
          final _error = error.toString().splitMapJoin(
            '\n',
            onNonMatch: (part) => '[$requestId] $part',
          );
          stderr
            ..writeln('[$requestId] Mirror error:')
            ..writeln(_error);

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
