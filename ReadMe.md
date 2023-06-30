# dev-mirror

Simple mirror (proxy) server for private APIs testing.
It will help you to keep private credentials out of build artifacts.

## Features

* Remote server authentication
* Local server authentication
* Referrer spoofing (pretend that request came from target origin)
* CORS bypass
* HTTP proxy support
* Adds `Access-Control-Expose-Headers` to allow browser inspect headers.

## Usage

### From console

You only need to provide `REMOTE_URI` and optionally `LOCAL_URI` (defaults to
`http://127.0.0.1:8080`)

```shell
REMOTE_URI=http://localhost:8080/
LOCAL_URI=http://127.0.0.1:8081/
```

### Via config (`.env` file)
Use environmental variables or `.env` file in working directory or pass it's
location as first argument:

```dotenv
## Remote HTTP(S) server

# Remote server URI (preferred)
REMOTE_URI = https://username:pa$$w0rd@example.com:443/

# Or exploded URI
SERVER_SCHEME = https
SERVER_HOST = example.com
SERVER_PORT = 443
# Remote server HTTP Basic auth (optional)
REMOTE_USERNAME = user
REMOTE_PASSWORD = passw0rd

## Local HTTP server

# Local server URI (preferred)
LOCAL_URI = http://user:passw0rd@127.0.0.1:8080/
# Or exploded URI
LOCAL_HOST = 127.0.0.1
LOCAL_PORT = 8080
# Local server HTTP Basic auth (optional)
LOCAL_USERNAME = user
LOCAL_PASSWORD = passw0rd

# HTTP proxy (optional)
HTTP_PROXY = http://username:pa$$w0rd@example.com:1337/
```

## Notes

Keep in mind that if you have local server authentication, you won't be able
to send authentication details to a remote server through a mirror.

That means that configuration in which a remote server requires authentication
and a mirror has no remote credentials but has local authentication is invalid.
To fix this, add remote credentials (recommended), or disable local
authentication.
