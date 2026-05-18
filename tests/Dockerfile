FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake gcc make git curl ca-certificates xz-utils \
    libc-dev \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Build miniupnpd with stub redirector: no iptables/nftables needed, always
# returns success for port mapping requests — safe for isolated test containers.
COPY tests/miniupnpd_stub_rdr.c /tmp/stub_rdr.c
RUN git clone --depth=1 --branch miniupnpd_2_3_9 \
        https://github.com/miniupnp/miniupnp.git /tmp/miniupnp \
    && cd /tmp/miniupnp/miniupnpd \
    && ./configure \
    && cp /tmp/stub_rdr.c . \
    && make NETFILTEROBJS=stub_rdr.o miniupnpd \
    && install -m 755 miniupnpd /usr/local/sbin/miniupnpd \
    && sed -i 's/^#define ENABLE_PCP$/\/*#define ENABLE_PCP*\//' config.h \
    && make NETFILTEROBJS=stub_rdr.o miniupnpd \
    && install -m 755 miniupnpd /usr/local/sbin/miniupnpd-natpmponly \
    && rm -rf /tmp/miniupnp /tmp/stub_rdr.c

# Install Nim
ARG NIM_VERSION=2.2.10
RUN curl -fsSL "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz" \
    | tar -xJ -C /opt && \
    ln -s "/opt/nim-${NIM_VERSION}/bin/nim" /usr/local/bin/nim && \
    ln -s "/opt/nim-${NIM_VERSION}/bin/nimble" /usr/local/bin/nimble

# Install nim deps (cached layer)
WORKDIR /app
COPY libplum.nimble .
COPY libplum/ libplum/
COPY vendor/ vendor/
RUN nimble setup -y

# Build libplum static library
RUN cmake -B vendor/libplum/build \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    vendor/libplum && \
    cmake --build vendor/libplum/build

# Compile test binaries (protocol x memory manager)
COPY tests/ tests/
RUN nim c -d:miniupnp_protocol=pcp   --mm:orc  -o:tests/test_pcp_orc   tests/test_plum.nim && \
    nim c -d:miniupnp_protocol=pcp   --mm:refc -o:tests/test_pcp_refc  tests/test_plum.nim && \
    nim c -d:miniupnp_protocol=upnp  --mm:orc  -o:tests/test_upnp_orc  tests/test_plum.nim && \
    nim c -d:miniupnp_protocol=upnp  --mm:refc -o:tests/test_upnp_refc tests/test_plum.nim && \
    nim c -d:miniupnp_protocol=natpmp --mm:orc  -o:tests/test_natpmp_orc  tests/test_plum.nim && \
    nim c -d:miniupnp_protocol=natpmp --mm:refc -o:tests/test_natpmp_refc tests/test_plum.nim

COPY tests/docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
