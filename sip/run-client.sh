#!/usr/bin/env bash
# SIP UAC (client). This container shares the network namespace of an OAI
# nr-ue (network_mode: "service:oai-nr-ue-1"), so it sees the UE data-plane
# tunnel interface (oaitun_ue1) with the IP assigned by the 5G core.
#
# It then:
#   1. waits for the UE tunnel to come up and get an IP,
#   2. installs a route to the SIP server *via the UE tunnel* so the traffic
#      is FORCED through the 5G data plane (UE -> RFsim -> gNB -> N3/GTP-U ->
#      UPF -> N6) instead of leaking out the container's eth0,
#   3. pings the server (proves IP connectivity through the core),
#   4. runs a SIP UAC scenario against the server.
set -euo pipefail

IFACE="${UE_IFACE:-oaitun_ue1}"
SIP_SERVER="${SIP_SERVER:?set SIP_SERVER as host:port}"
SERVER_NET="${SERVER_NET:-10.100.0.0/24}"
CALLS="${CALLS:-10}"
RATE="${RATE:-1}"

SERVER_HOST="${SIP_SERVER%%:*}"

echo "[sip-client] waiting for ${IFACE} to get an IPv4 address ..."
UE_IP=""
for _ in $(seq 1 150); do
    UE_IP="$(ip -4 -o addr show dev "${IFACE}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
    [ -n "${UE_IP}" ] && break
    sleep 2
done
if [ -z "${UE_IP}" ]; then
    echo "[sip-client] ERROR: ${IFACE} never came up / got no IP" >&2
    ip addr >&2 || true
    exit 1
fi
echo "[sip-client] UE data-plane IP (${IFACE}) = ${UE_IP}"

# Force the SIP server subnet through the 5G tunnel (more specific than the
# container default route, so it wins even though eth0 could also reach it).
ip route replace "${SERVER_NET}" dev "${IFACE}"
echo "[sip-client] route: $(ip route get "${SERVER_HOST}" 2>/dev/null | head -1)"

echo "[sip-client] IP connectivity check: ping ${SERVER_HOST} from ${UE_IP} ..."
if ping -c 4 -I "${UE_IP}" "${SERVER_HOST}"; then
    echo "[sip-client] ping OK -> IP connectivity through the 5G core works"
else
    echo "[sip-client] WARNING: ping failed, still attempting SIP" >&2
fi

echo "[sip-client] sending ${CALLS} SIP call(s) @ ${RATE}/s from ${UE_IP} -> ${SIP_SERVER}"
# -sn uac: built-in INVITE/ACK/BYE client scenario. Bind source to the UE IP
# so the 5-tuple uses the data-plane interface.
set +e
sipp -sn uac -i "${UE_IP}" -p 5060 "${SIP_SERVER}" -m "${CALLS}" -r "${RATE}" \
    -trace_stat -trace_err -timeout 30s
rc=$?
set -e

echo "[sip-client] sipp exit code = ${rc}"
if [ "${rc}" -eq 0 ]; then
    echo "[sip-client] SUCCESS: SIP dialog(s) completed over the 5G data plane"
else
    echo "[sip-client] sipp returned ${rc} (see stats above)"
fi

# keep the container alive so you can inspect / re-run manually
echo "[sip-client] done; sleeping so the namespace stays inspectable"
tail -f /dev/null
