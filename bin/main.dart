import 'dart:io';

import 'package:dev_mirror/config.dart';
import 'package:dev_mirror/secure_compare.dart';
import 'package:dev_mirror/uri_basic_auth.dart';
import 'package:dev_mirror/uri_credentials.dart';
import 'package:dev_mirror/uri_has_origin.dart';
import 'package:uri/uri.dart';


/// Invalid string URI.
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


/// List of additional root CA
final List<String> trustedRoots = [
  [72, 80, 78, 151, 76, 13, 172, 91, 92, 212, 118, 200, 32, 34, 116, 178, 76, 140, 113, 114], // DST Root CA X3
].map(String.fromCharCodes).toList();

/// Adds CORS headers to [response]
void addCORSHeaders(HttpRequest request, HttpResponse response) {
  final refererUri = Uri.tryParse(
    request.headers[HttpHeaders.refererHeader]?.singleOrNull ?? '::INVALID::',
  );
  response.headers
    ..set(
      HttpHeaders.accessControlAllowOriginHeader,
      (refererUri != null && refererUri.hasOrigin)
        ? refererUri.origin
        : '*',
    )
    ..set(
      HttpHeaders.accessControlAllowMethodsHeader,
      request.headers[HttpHeaders.accessControlRequestMethodHeader]?.join(',')
        ?? '*',
    )
    ..set(
      HttpHeaders.accessControlAllowHeadersHeader,
      request.headers[HttpHeaders.accessControlRequestHeadersHeader]?.join(',')
        ?? 'authorization,*',
    )
    ..set(
      HttpHeaders.accessControlAllowCredentialsHeader,
      'true',
    )
    ..set(
      HttpHeaders.accessControlExposeHeadersHeader,
      request.headers[HttpHeaders.accessControlExposeHeadersHeader]?.join(',')
        ?? 'authorization,*',
    );
}

void main(List<String> arguments) async {
  final dotEnvFile = arguments.firstOrNull ?? '.env';
  final config = Config.load(dotEnvFile);

  stdout.write('Starting mirror server ${config.local} -> ${config.remote}');
  if (config.local.basicAuth != null)
    stdout.write(' [Local auth]');
  if (config.remote.basicAuth != null)
    stdout.write(' [Remote auth auto-fill]');
  if (config.proxy != null) {
    stdout.write(' [Through HTTP proxy]');
    if (config.proxy!.scheme != 'http') {
      stdout.writeln(' [Error]');
      stderr.writeln('Proxy URI must be valid.');
      return;
    }
  }

  late final HttpServer server;
  try {
    server = await HttpServer.bind(config.local.host, config.local.port);
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

  // Allow SSL debugging
  if (config.sslKeyLogFile case final path?) {
    final keyLog = File(path)
      ..createSync(recursive: true);
    client.keyLog = (line) =>
      keyLog.writeAsStringSync(line, mode: FileMode.append);
  }

  // Apply HTTP proxy
  if (config.proxy case final Uri proxy) {
    final credentials = proxy.httpClientCredentials;
    if (credentials != null) {
      client.addProxyCredentials(
        proxy.host,
        proxy.port,
        'Basic',
        credentials,
      );
    }
    client.findProxy = (uri) => 'PROXY ${proxy.host}:${proxy.port}';
  }

  var requestId = 0;

  server.listen((request) {
    requestId++;

    final response = request.response;

    // Handle preflight
    if (
      request.method.toUpperCase() == 'OPTIONS' &&
      request.headers[HttpHeaders.accessControlRequestMethodHeader] != null
    ) {
      addCORSHeaders(request, response);
      stdout.writeln('[$requestId] Preflight handled.');
      response
        ..contentLength = 0
        ..statusCode = HttpStatus.ok
        ..close()
        .ignore();
      return;
    }

    final localBasicAuth = config.local.basicAuth;
    if (localBasicAuth != null) {
      final _userAuth = request.headers[HttpHeaders.authorizationHeader]?.singleOrNull;
      if (_userAuth == null || !secureCompare(_userAuth, localBasicAuth)) {
        stdout.writeln('[$requestId] Unauthorized access denied.');
        response
          ..statusCode = HttpStatus.unauthorized
          ..headers.add(HttpHeaders.wwwAuthenticateHeader, 'Basic realm=Protected')
          ..headers.contentType = ContentType.text
          ..write('PROXY///ERROR///UNAUTHORIZED')
          ..close()
          .ignore();
        return;
      }
    }

    final remoteUri = (UriBuilder.fromUri(request.uri)
      ..scheme = config.remote.scheme
      ..host = config.remote.host
      ..port = config.remote.port
    ).build();

    stdout.writeln('[$requestId] Forwarding: ${request.method} $remoteUri');

    (client..userAgent = request.headers[HttpHeaders.userAgentHeader]?.singleOrNull)
      .openUrl(request.method, remoteUri)
      .then((requestToRemote) async {
        requestToRemote.followRedirects = false;

        request.headers.forEach((headerName, headerValues) {
          // Filter out headers
          if (!headersNotToForwardToRemote.contains(headerName)) {
            // Spoof headers to look like from the original server
            if (headersToSpoofBeforeForwardToRemote.contains(headerName))
              requestToRemote.headers.add(
                headerName,
                headerValues.map(
                  (value) => value.replaceAll(config.local.toString(), config.remote.toString()),
                ),
              );
            else
            // Forward headers as-is
              requestToRemote.headers.add(headerName, headerValues);
          }
        });

        // Remote server auth
        final remoteBasicAuth = config.remote.basicAuth;
        if (remoteBasicAuth != null)
          requestToRemote.headers.set(HttpHeaders.authorizationHeader, remoteBasicAuth);

        // If there's content pipe request body
        if (request.contentLength > 0)
          await requestToRemote.addStream(request);

        return requestToRemote.close();
      })
      .then(
        (remoteResponse) {
          stdout.writeln('[$requestId] Remote response: ${remoteResponse.statusCode}');
          remoteResponse.headers.forEach((headerName, headerValues) {
            // Filter out headers
            if (!headersNotToForwardFromRemote.contains(headerName))
              // Spoof headers, so they'll point to mirror
              if (headersToSpoofBeforeForwardFromRemote.contains(headerName))
                response.headers.add(
                  headerName,
                  headerValues.map(
                    (value) => value.replaceAll(config.remote.toString(), config.local.toString()),
                  ),
                );
              // Add headers as-is
              else
                response.headers.add(headerName, headerValues);
          });
          response.statusCode = remoteResponse.statusCode;
          addCORSHeaders(request, response);

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

          addCORSHeaders(request, response);
          response
            ..statusCode = HttpStatus.internalServerError
            ..headers.contentType = ContentType.text
            ..writeln('PROXY///ERROR///INTERNAL')
            ..write(error)
            ..close()
            .ignore();
        },
      )
      .ignore();
  });
}
