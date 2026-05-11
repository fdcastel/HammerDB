# HammerDB Docker — Firebird

Builds an image with HammerDB plus the Firebird client libraries
(`libfbclient`, `firebird3.0-utils`) and the Firebird ODBC driver
(`libOdbcFb.so`) registered as `Firebird ODBC Driver` in
`/etc/odbcinst.ini`.

## Build

```sh
docker build -t hammerdb-firebird Docker/firebird/
```

## Run (Firebird Embedded — no server required)

```sh
docker run -it --rm hammerdb-firebird bash
# inside the container:
./hammerdbcli auto scripts/tcl/firebird/tprocc/fb_tprocc_buildschema.tcl
```

`config/firebird.xml` defaults to `fb_embedded=true`, so HammerDB
opens the `.fdb` directly via the embedded engine. The default
database path is `${TMP}/tpcc.fdb` — set the environment variable
`TMP` to control where it lands.

## Notes

- The image is based on `tpcorg/hammerdb:v5.0-base` and follows the
  same overlay pattern as `Docker/{mysql,postgres,maria,mssqls}`.
- The Firebird ODBC driver download URL (`FB_ODBC_URL` build arg) is
  pinned to the 3.0.1 release (tag `v3-0-1-release`, asset
  `linux_libs.zip`) to match the `choco install firebird-odbc`
  package used by the Windows CI workflow. Override at build time if
  you need a different release:

  ```sh
  docker build --build-arg FB_ODBC_URL=https://... -t hammerdb-firebird Docker/firebird/
  ```

- For server-mode Firebird (remote .fdb), set `fb_embedded=false` in
  `config/firebird.xml` and provide `fb_host`/`fb_port` for the
  Firebird server. The image includes `firebird3.0-utils` (`isql`,
  `gbak`, `gstat`) for ad-hoc database administration.

## Status

This Dockerfile is committed as a documented starting point. End-to-
end CI validation on a `ubuntu-latest` runner is tracked under Phase
F4 in `tmp/THE_PLAN.md`.
