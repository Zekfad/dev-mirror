import 'dart:convert';


extension UriBasicAuth on Uri {
  String? get basicAuth => userInfo.isNotEmpty
    ? 'Basic ${base64Encode(utf8.encode(userInfo))}'
    : null;
}
