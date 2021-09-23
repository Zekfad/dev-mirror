# dev-mirror

Simple mirror (proxy) server for private APIs testing which will help you
to keep your private credentials out of build artifacts.

## Features

* Target server authentication
* Local server authentication
* Spoofing referer
* CORS bypass

## Usage

Use environmental variables or `.env`:
```.env
SERVER_SCHEME = https
SERVER_HOST = example.com
SERVER_PORT = 443
# HTTP Basic auth
SERVER_USERNAME = user
SERVER_PASSWORD = passw0rd
LOCAL_PORT = 8080
# HTTP Basic auth
LOCAL_USERNAME = user
LOCAL_PASSWORD = passw0rd
```

Keep in mind, that if you have local server authentication without target
server authentication you wont be able to authenticate.

