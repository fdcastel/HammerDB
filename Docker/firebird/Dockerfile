# HammerDB Docker image with Firebird client libraries.
#
# Adds to the base HammerDB image:
#   - Firebird Embedded engine (libfbclient + libib_util) so HammerDB
#     can open .fdb files in-process via tdbc::odbc.
#   - Firebird ODBC driver (libOdbcFb.so) registered in
#     /etc/odbcinst.ini so the bundled tdbc::odbc 1.1.x can find it
#     by the name "Firebird ODBC Driver" - matches the Windows
#     registration set up by `choco install firebird-odbc` and the
#     `fb_odbc_driver` default in `config/firebird.xml`.
#
# Build:
#   docker build -t hammerdb-firebird Docker/firebird/
#
# Run (embedded mode, no Firebird server needed):
#   docker run -it --rm -v $PWD:/work hammerdb-firebird bash
#   ./hammerdbcli auto scripts/tcl/firebird/tprocc/fb_tprocc_buildschema.tcl

FROM docker.io/tpcorg/hammerdb:v5.0-base

USER root

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        firebird3.0-utils \
        libfbclient2 \
        unixodbc \
        wget \
        unzip \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Install Firebird ODBC driver. Official builds at
# https://github.com/FirebirdSQL/firebird-odbc-driver/releases.
# Tag uses the `vM-N-P-release` form (not `vM.N.P`) and the asset is
# a .zip, not a .tar.gz. Override at build time if a newer release is
# wanted.
ARG FB_ODBC_URL="https://github.com/FirebirdSQL/firebird-odbc-driver/releases/download/v3-0-1-release/linux_libs.zip"

RUN set -eux; \
    mkdir -p /opt/firebird-odbc; \
    cd /opt/firebird-odbc; \
    wget -q -O OdbcFb.zip "${FB_ODBC_URL}"; \
    unzip -j OdbcFb.zip; \
    rm OdbcFb.zip; \
    ls -la; \
    so=$(ls -1 *OdbcFb*.so 2>/dev/null | head -n 1); \
    if [ -z "$so" ]; then so=$(ls -1 *.so | head -n 1); fi; \
    install -m 0755 "$so" /usr/lib/x86_64-linux-gnu/libOdbcFb.so; \
    {                                                       \
        echo "[Firebird ODBC Driver]";                      \
        echo "Description=Firebird ODBC Driver";            \
        echo "Driver=/usr/lib/x86_64-linux-gnu/libOdbcFb.so"; \
        echo "Setup=/usr/lib/x86_64-linux-gnu/libOdbcFb.so";  \
        echo "Threading=1";                                 \
        echo "UsageCount=1";                                \
    } | tee -a /etc/odbcinst.ini

# Embedded-mode reminder: applications open the .fdb directly via
# fbclient.so without contacting a server. config/firebird.xml has
# fb_embedded=true and the connection string template
# `Driver={Firebird ODBC Driver};Dbname=<path>;Client=libfbclient.so;User=SYSDBA;`
# is built by src/firebird/fboltp.tcl::fb_build_connstr.

# Base image already sets USER and WORKDIR; do not override here
# (matches Docker/{mysql,postgres,maria,mssqls}/Dockerfile).
