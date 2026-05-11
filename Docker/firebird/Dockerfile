# HammerDB Docker image with Firebird client libraries.
#
# Adds to the base HammerDB image:
#   - Firebird 3 client + embedded engine + ODBC driver
#     (libfbclient.so, libEngine12.so, libOdbcFb.so) so HammerDB can
#     open .fdb files in-process via tdbc::odbc or connect to an
#     external Firebird server.
#   - System Tcl + tcl8.6-tdbc-odbc, so the standalone CI scripts
#     under .github/workflows/scripts/fb_*.tcl can `package require
#     tdbc::odbc` and load libOdbcFb. The HammerDB binary itself
#     ships its own bundled Tcl runtime and is not affected.
#
# Build:
#   docker build -t hammerdb-firebird Docker/firebird/
#
# Run (embedded mode, no Firebird server needed):
#   docker run -it --rm -v $PWD:/work hammerdb-firebird bash

FROM docker.io/tpcorg/hammerdb:v5.0-base

USER root

# firebird3.0-server-core ships libEngine12.so (the embedded engine
# plugin libfbclient loads when given a local path) and the default
# firebird.conf with Providers=Remote,Engine12,Loopback. Without it,
# libfbclient on Linux falls back to the Remote provider and fails
# CREATE DATABASE with "Unable to complete network request to host
# localhost" for embedded connections.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        firebird3.0-server-core \
        firebird3.0-utils \
        gcc \
        libfbclient2 \
        tcl \
        tcl8.6-tdbc-odbc \
        unixodbc unixodbc-dev \
        unzip \
        wget && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf libfbclient.so.2 /usr/lib/x86_64-linux-gnu/libfbclient.so

# Firebird ODBC driver. Pinned to an unofficial v3.5.1-rc1 build that
# applies the fix for the unchecked C-style downcast in the catch
# block of OdbcConnection::connect (the official v3.5.0-rc1 returns a
# garbled diagnostic record on every failed SQLDriverConnect on
# Linux, which makes the driver unusable behind tdbc::odbc). Once the
# fix lands in an upstream release, this URL should be moved back to
# github.com/FirebirdSQL/firebird-odbc-driver. Override FB_ODBC_URL
# at build time to pin a different build.
ARG FB_ODBC_URL="https://github.com/fdcastel/firebird-odbc-driver/releases/download/v3.5.1-rc1/firebird-odbc-driver-3.5.1-rc1-linux-x64.tar.gz"
RUN set -eux; \
    mkdir -p /opt/firebird-odbc; \
    cd /opt/firebird-odbc; \
    wget -q -O OdbcFb.tar.gz "${FB_ODBC_URL}"; \
    tar -xzf OdbcFb.tar.gz; \
    rm OdbcFb.tar.gz; \
    install -m 0755 libOdbcFb.so /usr/lib/x86_64-linux-gnu/libOdbcFb.so; \
    {                                                            \
        echo "[Firebird ODBC Driver]";                           \
        echo "Description=Firebird ODBC Driver";                 \
        echo "Driver=/usr/lib/x86_64-linux-gnu/libOdbcFb.so";    \
        echo "Setup=/usr/lib/x86_64-linux-gnu/libOdbcFb.so";     \
        echo "Threading=1";                                      \
        echo "UsageCount=1";                                     \
    } | tee -a /etc/odbcinst.ini

# Base image already sets USER and WORKDIR; do not override here
# (matches Docker/{mysql,postgres,maria,mssqls}/Dockerfile).
