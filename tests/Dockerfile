FROM nimlang/nim:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake make \
    libc-dev \
    iproute2 \
    && apt-get dist-clean

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
    # Build another miniupnpd for pmp: we need to disable explictly PCP for that
    # check miniupnpd configure for more info.
    # https://github.com/miniupnp/miniupnp/blob/50cb0582d4a659e319050069aa84efbc1f353b14/miniupnpd/configure#L878-L880
    && sed -i 's/^#define ENABLE_PCP$/\/*#define ENABLE_PCP*\//' config.h \
    && make NETFILTEROBJS=stub_rdr.o miniupnpd \
    && install -m 755 miniupnpd /usr/local/sbin/miniupnpd-natpmponly \
    && rm -rf /tmp/miniupnp /tmp/stub_rdr.c

# Install nim deps (cached layer)
WORKDIR /app
COPY libplum.nimble .
COPY libplum/ libplum/
COPY vendor/ vendor/
RUN nimble setup -y

# Build libplum static library
RUN rm -rf vendor/libplum/build && \
    cmake -B vendor/libplum/build \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    vendor/libplum && \
    cmake --build vendor/libplum/build && \
    cp vendor/libplum/build/libplum.a vendor/libplum/libplum.a

# Compile test binaries (protocol x memory manager)
COPY tests/ tests/
RUN nim c -d:miniupnp_protocol=pcp   --mm:orc  --threads:on -o:tests/test_pcp_orc   tests/test_plum.nim && \
    nim c -d:miniupnp_protocol=pcp   --mm:refc --threads:on -o:tests/test_pcp_refc  tests/test_plum.nim && \
    nim c -d:miniupnp_protocol=upnp  --mm:orc  --threads:on -o:tests/test_upnp_orc  tests/test_plum.nim && \
    nim c -d:miniupnp_protocol=upnp  --mm:refc --threads:on -o:tests/test_upnp_refc tests/test_plum.nim && \
    nim c -d:miniupnp_protocol=natpmp --mm:orc  --threads:on -o:tests/test_natpmp_orc  tests/test_plum.nim && \
    nim c -d:miniupnp_protocol=natpmp --mm:refc --threads:on -o:tests/test_natpmp_refc tests/test_plum.nim

COPY tests/docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
