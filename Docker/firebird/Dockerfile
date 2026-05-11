# HammerDB Docker image with Firebird client libraries.
#
# Adds to the base HammerDB image:
#   - Firebird Embedded engine + ODBC driver (libfbclient.so,
#     libOdbcFb.so) for users who want to point HammerDB at a
#     Firebird database from within the container.
#   - System Tcl + tcl8.6-tdbc-odbc, so the standalone CI scripts
#     under .github/workflows/scripts/fb_*.tcl can `package require
#     tdbc::odbc` and load libOdbcFb. The HammerDB binary itself
#     ships its own bundled Tcl runtime and is not affected.
#
# Linux SQL coverage caveat: the official Firebird ODBC driver
# (libOdbcFb.so) returns garbage native error codes and SQLSTATE
# `00000` on any failed connection - making the driver unusable
# behind tdbc::odbc for real workloads. The CI job here builds the
# image and verifies the binaries load, but does not exercise SQL
# round-trips on Linux. The Windows job covers the full SQL path
# end-to-end. See src/firebird/README.md for the long story.
#
# Build:
#   docker build -t hammerdb-firebird Docker/firebird/
#
# Run (point hammerdbcli at an external Firebird server):
#   docker run -it --rm -v $PWD:/work hammerdb-firebird bash

FROM docker.io/tpcorg/hammerdb:v5.0-base

USER root

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        firebird3.0-utils \
        libfbclient2 \
        tcl \
        tcl8.6-tdbc-odbc \
        unixodbc \
        unzip \
        wget && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf libfbclient.so.2 /usr/lib/x86_64-linux-gnu/libfbclient.so

# Firebird ODBC driver. Official builds at
# https://github.com/FirebirdSQL/firebird-odbc-driver/releases.
# v3.5.0-rc1 is the first build paired with Firebird 5 client.
# Override FB_ODBC_URL at build time to pin a different release.
ARG FB_ODBC_URL="https://github.com/FirebirdSQL/firebird-odbc-driver/releases/download/v3.5.0-rc1/firebird-odbc-driver-3.5.0-rc1-linux-x64.tar.gz"
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
