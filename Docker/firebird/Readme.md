# HammerDB Docker — Firebird

Builds an image with HammerDB plus the Firebird client libraries
(`libfbclient`, `firebird3.0-utils`) and the Firebird ODBC driver
(`libOdbcFb.so`) registered as `Firebird ODBC Driver` in
`/etc/odbcinst.ini`.

## Build

```sh
docker build -t hammerdb-firebird Docker/firebird/
```

## Run

```sh
docker run -it --rm hammerdb-firebird bash
# inside the container, point HammerDB at your Firebird database
# (Firebird Embedded or a Firebird server reachable via TCP).
```

The image is based on `tpcorg/hammerdb:v5.0-base` and follows the
same overlay pattern as `Docker/{mysql,postgres,maria,mssqls}`.

The Firebird ODBC driver download URL (`FB_ODBC_URL` build arg) is
pinned to an unofficial `v3.5.1-rc1` build at
[github.com/fdcastel/firebird-odbc-driver](https://github.com/fdcastel/firebird-odbc-driver/releases/tag/v3.5.1-rc1)
that fixes a downcast bug in `OdbcConnection::connect` which would
otherwise return a garbled diagnostic record on every failed
`SQLDriverConnect` on Linux. Once the fix lands in an upstream
release this should move back to
`github.com/FirebirdSQL/firebird-odbc-driver`. Override at build
time to pin a different release:

```sh
docker build --build-arg FB_ODBC_URL=https://... -t hammerdb-firebird Docker/firebird/
```
