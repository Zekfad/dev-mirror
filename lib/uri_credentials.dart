import 'dart:io';


extension UriCredentials on Uri {
  ({ String username, String password, })? get credentials {
    final credentialsMatch = RegExp(r'^(?<username>.+?):(?<password>.+?)$')
      .firstMatch(userInfo);
    final username = credentialsMatch?.namedGroup('username');
    final password = credentialsMatch?.namedGroup('password');
    if (username == null || password == null)
      return null;
    return (username: username, password: password);
  }

  HttpClientBasicCredentials? get httpClientCredentials => switch(credentials) {
    (:final username, :final password) => HttpClientBasicCredentials(
      username,
      password,
    ),
    _ => null,
  };
}
