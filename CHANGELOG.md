# 1.2.1

- Fix HTTP_PROXY variable.

# 1.2.0

- Add `Access-Control-Expose-Headers` header if none is provided by server.
- Rename environment variables:
  `SERVER_SCHEME` -> `REMOTE_SCHEME`
  `SERVER_HOST` -> `REMOTE_HOST`
  `SERVER_USERNAME` -> `REMOTE_USERNAME`
  `SERVER_PASSWORD` -> `REMOTE_PASSWORD`
  `SERVER_POST` -> `REMOTE_POST`
  `LOCAL_BIND_IP` -> `LOCAL_HOST`
- Now you can use just `LOCAL_URI` and `REMOTE_URI` same as `HTTP_PROXY`,
  this simplifies usage from console.

# 1.1.2

- Add support for internal redirects.
- Make log more useful for multiple concurrent requests.

# 1.1.1

- Update linter rules.

# 1.1.0

- HTTP Proxy support.

# 1.0.1

- Initial version.
