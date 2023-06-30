extension UriHasOrigin on Uri {
  bool get hasOrigin => (scheme == 'http' || scheme == 'https') && host != '';
}
