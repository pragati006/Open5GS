#!/usr/bin/env bash
# Generate a LABELLED RTP dataset for the loss-cause classifier by driving baresip
# calls over 5G under three user-plane conditions, impaired with tc on the caller's
# tunnel (ue2 uplink) and captured at the callee (ue1, downstream of the impairment):
#
#   clean       no impairment
#   radio       netem bursty loss, NO added delay      (random link loss)
#   congestion  tbf rate below the media bitrate       (queue builds -> delay+loss)
#
# The call is established FIRST, then the impairment is applied only for the capture
# window, so SIP setup is never affected.
set -u
cd /home/pragati/linux_workspace/Open5GS
mkdir -p ml/data
IFACE=oaitun_ue1
RELAY=10.100.0.11
HOLD="${HOLD:-22}"
DC="docker compose -f docker-compose.yaml -f docker-compose.sip.yaml"

echo "=== ensure baresip tone softphones are up (free linphonec ports) ==="
docker rm -f phone-ue1 phone-ue2 >/dev/null 2>&1 || true
$DC up -d baresip-ue1 baresip-ue2 >/dev/null 2>&1
echo "waiting 30s for registration ..."; sleep 30

tc_clear() { docker exec baresip-ue2 tc qdisc del dev "$IFACE" root >/dev/null 2>&1 || true; }

run_scenario() {   # $1=label   $2=tc command (empty = none)
    local label="$1" tccmd="$2"
    echo "--- scenario: ${label} ---"
    tc_clear
    docker exec baresip-ue2 python3 /baresip-ctrl.py hangup >/dev/null 2>&1 || true
    docker exec baresip-ue1 python3 /baresip-ctrl.py hangup >/dev/null 2>&1 || true
    sleep 3
    docker exec baresip-ue2 python3 /baresip-ctrl.py dial sip:ue1@10.100.0.10 >/dev/null 2>&1
    sleep 8   # let media fully establish on BOTH legs before capturing
    echo -n "   call: "
    docker exec baresip-ue2 python3 /baresip-ctrl.py listcalls 2>/dev/null | grep -o 'Active calls ([0-9]*)' || echo "?"
    # capture the received stream at the callee (downstream of the impairment)
    docker exec -d baresip-ue1 sh -c "rm -f /tmp/cap.pcap; timeout $((HOLD+3)) tcpdump -ni $IFACE -w /tmp/cap.pcap 'udp and host $RELAY' >/dev/null 2>&1"
    sleep 1
    if [ -n "$tccmd" ]; then
        docker exec baresip-ue2 sh -c "$tccmd" && echo "   applied: $tccmd"
    fi
    sleep "$HOLD"
    tc_clear
    sleep 1
    docker cp baresip-ue1:/tmp/cap.pcap "ml/data/${label}.pcap" >/dev/null 2>&1
    echo "   saved ml/data/${label}.pcap ($(docker exec baresip-ue1 sh -c 'wc -c < /tmp/cap.pcap' 2>/dev/null) bytes)"
    docker exec baresip-ue2 python3 /baresip-ctrl.py hangup >/dev/null 2>&1 || true
}

# verify tc is available in the caller container
if ! docker exec baresip-ue2 sh -c 'command -v tc' >/dev/null 2>&1; then
    echo "ERROR: 'tc' not found in baresip-ue2 (need iproute2)"; exit 1
fi

run_scenario clean      ""
run_scenario radio      "tc qdisc add dev $IFACE root netem loss 7% 30%"
run_scenario congestion "tc qdisc add dev $IFACE root tbf rate 56kbit burst 2kb latency 500ms"
tc_clear

echo "=== captured pcaps ==="
ls -l ml/data/*.pcap
echo "next: bash scripts/rtp-train.sh"
