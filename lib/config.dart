import 'dart:io';

import 'package:dotenv/dotenv.dart';

class Config {
  const Config._({
    required this.local,
    required this.remote,
    this.proxy,
    this.sslKeyLogFile,
  });

  factory Config.load(String? path) {
    if (path != null && File(path).existsSync())
      dotenv.load([ path, ]);

    final proxy = getUri('HTTP_PROXY', true);

    final sslKeyLogFile = getString('SSLKEYLOGFILE');

    final local = getUri('LOCAL')
      ?? Uri.http('127.0.0.1:8080');

    final remote = getUri('REMOTE')
      ?? Uri.https('example.com');

    return Config._(
      proxy: proxy,
      sslKeyLogFile: sslKeyLogFile,
      local: local,
      remote: remote,
    );
  }

  final Uri? proxy;
  final String? sslKeyLogFile;
  final Uri local;
  final Uri remote;

  static final dotenv = DotEnv();

  /// Returns environment variable or `.env` variable
  static String? getString(String variable) =>
    Platform.environment[variable] ?? dotenv[variable];

  static T? getNum<T extends num>(String variable) => switch(getString(variable)) {
    final String value => switch(T) {
      const (double) => double.tryParse(value),
      const (int) => int.tryParse(value),
      _ => null,
    } as T?,
    _ => null,
  };

  static Uri? getUri(String prefix, [bool noSuffixForFullUri = false]) =>
    getFullUri(noSuffixForFullUri ? prefix : '${prefix}_URI') ??
    getExplodedUri(prefix);

  static Uri? getFullUri(String variable) => switch(getString(variable)) {
    final String value => Uri.tryParse(value),
    _ => null,
  };

  static Uri? getExplodedUri(String prefix) => switch((
    getString('${prefix}_SCHEME'),
    getString('${prefix}_HOST'),
  )) {
    (final scheme?, final host?) => Uri(
      scheme: scheme,
      userInfo: switch((
        getString('${prefix}_USERNAME'),
        getString('${prefix}_PASSWORD'),
      )) {
        (final username?, final password?) => '$username:$password',
        _ => null, 
      },
      host: host,
      port: getNum('${prefix}_PORT') ?? switch(scheme) {
        'https' => 443,
        'http' => 80,
        _ => null,
      },
    ),
    _ => null,
  };
}
