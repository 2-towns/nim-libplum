#!/bin/bash
set -euo pipefail

RUNDIR=/tmp/plum-test
mkdir -p "$RUNDIR"

# miniupnpd must listen on the same interface as libplum.
# we get the default route interface (e.g. eth0) and use it to receive libplum requests.
LAN_IF=$(ip route show default | awk '/default/{print $5; exit}')
# get its IP and use it as a fake router so libplum sends PCP/NAT-PMP requests to miniupnpd.
LAN_IP=$(ip -4 addr show "$LAN_IF" | awk '/inet /{print $2; exit}' | cut -d/ -f1)

# we use a public WAN IP (1.2.3.4) on a dummy interface because miniupnpd disables
# port forwarding when the external interface has a private/RFC1918 address (treats it as double-NAT).
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
    # PCP requires the UDP source IP to match the client_address in the MAP request.
    # we point the default route at LAN_IP so libplum uses it as both gateway and source IP.
    ip route replace default via "$LAN_IP" dev "$LAN_IF"
    start_miniupnpd pcp yes "$LAN_IF"
    run_tests pcp "$RUNDIR/miniupnpd-pcp.log"
fi

if [ "${TEST_MINIUPNP_UPNP:-}" = "1" ]; then
    start_miniupnpd upnp no "$LAN_IF"
    run_tests upnp "$RUNDIR/miniupnpd-upnp.log"
fi

if [ "${TEST_MINIUPNP_NATPMP:-}" = "1" ]; then
    # miniupnpd-natpmponly has no PCP support, so libplum falls back to NAT-PMP.
    # same route trick as PCP: point the default route at LAN_IP so libplum sends NAT-PMP to miniupnpd.
    ip route replace default via "$LAN_IP" dev "$LAN_IF"
    start_miniupnpd natpmp yes "$LAN_IF" miniupnpd-natpmponly
    run_tests natpmp "$RUNDIR/miniupnpd-natpmp.log"
fi

