#!/bin/bash
set -euo pipefail

RUNDIR=/tmp/plum-test
mkdir -p "$RUNDIR"

LAN_IF=$(ip route show default | awk '/default/{print $5; exit}')
LAN_IP=$(ip -4 addr show "$LAN_IF" | awk '/inet /{print $2; exit}' | cut -d/ -f1)

# Use a public (non-reserved) WAN IP. miniupnpd disables port forwarding when
# the external interface has a private/RFC1918 address (treats it as double-NAT).
ip link add plum-wan type dummy
ip addr add 1.2.3.4/24 dev plum-wan
ip link set plum-wan up

start_miniupnpd() {
    local proto=$1 enable_pcp_pmp=$2 listen_on=$3 binary=${4:-miniupnpd}
    local conf="$RUNDIR/miniupnpd-$proto.conf"
    local pidfile="$RUNDIR/miniupnpd-$proto.pid"

    cat > "$conf" << EOF
ext_ifname=plum-wan
listening_ip=$listen_on
enable_pcp_pmp=$enable_pcp_pmp
# port=0: pick a random HTTP port to avoid conflicts with host services.
port=0
# Without an allow rule miniupnpd denies all mapping requests by default,
# returning NO_RESOURCES (PCP) or ActionFailed (UPnP).
allow 1024-65535 0.0.0.0/0 1024-65535
EOF
    # -d: don't daemonize; we background it ourselves with & to capture the pid.
    "$binary" -d -f "$conf" > "$RUNDIR/miniupnpd-$proto.log" 2>&1 &
    echo $! > "$pidfile"
    sleep 1
    kill -0 "$(cat "$pidfile")" 2>/dev/null \
        || { echo "miniupnpd-$proto failed to start" >&2; exit 1; }
    echo "miniupnpd-$proto started (pid $(cat "$pidfile"))"
}

run_tests() {
    local proto=$1 logfile=$2
    local failed=0
    for mm in orc refc; do
        echo "--- $proto $mm ---"
        "/app/tests/test_${proto}_${mm}" || failed=1
    done
    if [ "${MINIUPNPD_VERBOSE:-}" = "1" ]; then
        echo "--- miniupnpd log ---"
        cat "$logfile" 2>/dev/null || true
    fi
    [ $failed -eq 0 ] || exit 1
}

if [ "${TEST_MINIUPNP_PCP:-}" = "1" ]; then
    # PCP requires the UDP source IP to equal the client_address field in the
    # MAP request header. libplum sets client_address by connecting a UDP socket
    # to the gateway IP. Pointing the default route at LAN_IP makes libplum
    # use LAN_IP as both the gateway (where it sends PCP) and the source IP,
    # so the two match and miniupnpd accepts the request without ADDRESS_MISMATCH.
    ip route replace default via "$LAN_IP" dev "$LAN_IF"
    start_miniupnpd pcp yes "$LAN_IF"
    run_tests pcp "$RUNDIR/miniupnpd-pcp.log"
fi

if [ "${TEST_MINIUPNP_UPNP:-}" = "1" ]; then
    start_miniupnpd upnp no "$LAN_IF"
    run_tests upnp "$RUNDIR/miniupnpd-upnp.log"
fi

if [ "${TEST_MINIUPNP_NATPMP:-}" = "1" ]; then
    # miniupnpd-natpmponly is compiled without ENABLE_PCP: PCP probes get no
    # response (timeout) and libplum must fall back to NAT-PMP on its own.
    # Same route trick as PCP: point the default route at LAN_IP so libplum
    # sends NAT-PMP to the local miniupnpd rather than the real gateway.
    ip route replace default via "$LAN_IP" dev "$LAN_IF"
    start_miniupnpd natpmp yes "$LAN_IF" miniupnpd-natpmponly
    run_tests natpmp "$RUNDIR/miniupnpd-natpmp.log"
fi

