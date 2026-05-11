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
pinned to the v3.5.0-rc1 release. Override at build time if you need
a different release:

```sh
docker build --build-arg FB_ODBC_URL=https://... -t hammerdb-firebird Docker/firebird/
```

## Linux SQL coverage caveat

The Firebird ODBC driver for Linux (verified on both `v3-0-1-release`
and `v3.5.0-rc1`) currently returns a garbled diagnostic record on
every failed `SQLDriverConnect` — empty SQLSTATE, non-deterministic
native error code, and a message truncated to a single `[` character.
HammerDB's Tcl driver (`tdbc::odbc`) cannot recover useful error
information from connections that go through this driver, so the
full SQL/PSQL path is exercised only on the Windows CI workflow. The
Linux CI job builds the image and verifies that `libfbclient`,
`libOdbcFb.so` and `tdbc::odbc` load correctly. See
`src/firebird/README.md` for details.
