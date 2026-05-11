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
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Install Firebird ODBC driver. The official builds are on GitHub
# Releases at https://github.com/FirebirdSQL/firebird-odbc-driver. We
# pin to the 3.0.x line to match the Windows `firebird-odbc` chocolatey
# package used by the GitHub Actions workflow.
ARG FB_ODBC_URL="https://github.com/FirebirdSQL/firebird-odbc-driver/releases/download/v3.0.1/OdbcFb-LIB-Linux-x86_64.tar.gz"

RUN set -eux; \
    mkdir -p /opt/firebird-odbc && \
    cd /opt/firebird-odbc && \
    wget -q -O OdbcFb.tar.gz "${FB_ODBC_URL}" && \
    tar -xzf OdbcFb.tar.gz && \
    rm OdbcFb.tar.gz && \
    install -m 0755 libOdbcFb.so /usr/lib/x86_64-linux-gnu/libOdbcFb.so && \
    printf '%s\n' \
        '[Firebird ODBC Driver]' \
        'Description=Firebird ODBC Driver' \
        'Driver=/usr/lib/x86_64-linux-gnu/libOdbcFb.so' \
        'Setup=/usr/lib/x86_64-linux-gnu/libOdbcFb.so' \
        'Threading=1' \
        'UsageCount=1' \
        >> /etc/odbcinst.ini && \
    odbcinst -q -d

# Embedded-mode reminder: applications open the .fdb directly via
# fbclient.so without contacting a server. config/firebird.xml has
# fb_embedded=true and the connection string template
# `Driver={Firebird ODBC Driver};Dbname=<path>;Client=libfbclient.so;User=SYSDBA;`
# is built by src/firebird/fboltp.tcl::fb_build_connstr.

USER hammerdb
WORKDIR /home/hammerdb
