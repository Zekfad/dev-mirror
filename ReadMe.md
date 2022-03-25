# dev-mirror

Simple mirror (proxy) server for private APIs testing.
It will help you to keep private credentials out of build artifacts.

## Features

* Target server authentication
* Local server authentication
* Spoofing referrer
* CORS bypass
* HTTP proxy support

## Usage

Use environmental variables or `.env` file in working directory or pass it's
location as first argument:
```dotenv
# Remote HTTP(S) server
SERVER_SCHEME = https
SERVER_HOST = example.com
SERVER_PORT = 443
# Remote server HTTP Basic auth (optional)
SERVER_USERNAME = user
SERVER_PASSWORD = passw0rd
# Local HTTP server
LOCAL_BIND_IP = 127.0.0.1
LOCAL_PORT = 8080
# Local server HTTP Basic auth (optional)
LOCAL_USERNAME = user
LOCAL_PASSWORD = passw0rd
# HTTP proxy (optional)
HTTP_PROXY = http://username:pa$$w0rd@example.com:1337/
```

Keep in mind that if you have local server authentication, you won't be able
to send authentication details to a remote server through a mirror.

That means that configuration in which a remote server requires authentication
and a mirror has no remote credentials but has local authentication is invalid.
To fix this, add remote credentials (recommended), or disable local
authentication.
