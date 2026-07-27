#!/usr/bin/env bash
# SIP UAS (server). Runs on the N6 "data network" that the UPF routes UE
# traffic to. It answers INVITE -> 180 Ringing -> 200 OK, waits for ACK,
# then BYE. This is pure SIP signalling over the 5G user plane (no VoLTE / IMS).
set -euo pipefail

BIND_IP="${BIND_IP:-0.0.0.0}"
PORT="${SIP_PORT:-5060}"

echo "[sip-server] sipp version: $(sipp -v 2>/dev/null | head -1 || true)"
echo "[sip-server] starting UAS on ${BIND_IP}:${PORT} (unlimited calls)"

# -sn uas : built-in server scenario. No -m => serve calls indefinitely.
exec sipp -sn uas -i "${BIND_IP}" -p "${PORT}" \
    -trace_msg -message_file /tmp/sip-server-msg.log \
    -trace_err
