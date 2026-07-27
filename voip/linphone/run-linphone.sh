#!/usr/bin/env bash
# Headless linphonec runner for the OTT VoIP-over-5G lab.
#
# Env vars:
#   SIP_USER, SIP_PASS, SIP_DOMAIN  – identity + Kamailio address
#   UE_IFACE                        – 5G tunnel iface (oaitun_ue1)
#   PEER_URI                        – URI to auto-call (caller only)
#   CALL_WAIT                       – s before dialling (default 30)
#   USE_AUDIO_DEV                   – "yes" => real mic/speaker via PulseAudio;
#                                     otherwise a silent/dummy device
set -u
SIP_USER="${SIP_USER:?}"; SIP_PASS="${SIP_PASS:?}"; SIP_DOMAIN="${SIP_DOMAIN:?}"
UE_IFACE="${UE_IFACE:-oaitun_ue1}"
PEER_URI="${PEER_URI:-}"
CALL_WAIT="${CALL_WAIT:-30}"
USE_AUDIO_DEV="${USE_AUDIO_DEV:-yes}"
RC=/root/.linphonerc
FIFO=/tmp/lin.in
LOG=/tmp/lin.log

# ---- wait for the 5G tunnel ----
echo "[linphone] waiting for ${UE_IFACE} ..."
UE_IP=""
for _ in $(seq 1 120); do
    UE_IP=$(ip -4 -o addr show dev "${UE_IFACE}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [ -n "${UE_IP}" ] && break
    sleep 2
done
[ -z "${UE_IP}" ] && { echo "[linphone] ERROR: ${UE_IFACE} no IP"; exit 1; }
echo "[linphone] UE data-plane IP = ${UE_IP}"

# ---- route the SIP/RTP servers through the 5G tunnel ----
ip route replace 10.100.0.0/24 dev "${UE_IFACE}"
echo "[linphone] route 10.100.0.0/24 -> ${UE_IFACE} OK"

# ---- audio device selection ----
if [ "${USE_AUDIO_DEV}" = "yes" ]; then
    PLAYBACK="PulseAudio: default"
    CAPTURE="PulseAudio: default"
    echo "[linphone] audio: PulseAudio (laptop mic/speaker via WSLg)"
else
    PLAYBACK=""
    CAPTURE=""
fi

# ---- write linphonerc ----
cat > "${RC}" <<EOF
[sip]
sip_port=5080
sip_tcp_port=-1
sip_tls_port=-1
guess_hostname=1
register_only_when_network_is_up=0
default_proxy=0

[rtp]
audio_rtp_port=7078
symmetric_rtp=1

[proxy_0]
reg_proxy=<sip:${SIP_DOMAIN}>
reg_identity=<sip:${SIP_USER}@${SIP_DOMAIN}>
reg_expires=60
reg_sendregister=1

[auth_info_0]
username=${SIP_USER}
passwd=${SIP_PASS}
realm=${SIP_DOMAIN}

[sound]
playback_dev_id=${PLAYBACK}
capture_dev_id=${CAPTURE}
ringer_dev_id=${PLAYBACK}
echocancellation=0

[net]
mtu=1300
EOF
echo "[linphone] linphonerc written for sip:${SIP_USER}@${SIP_DOMAIN}"

# ---- start linphonec reading commands from a FIFO ----
rm -f "${FIFO}"; mkfifo "${FIFO}"
# hold the FIFO open for writing so linphonec's stdin never closes
sleep infinity > "${FIFO}" &
HOLD=$!
echo "[linphone] starting linphonec ..."
linphonec -c "${RC}" -d 3 < "${FIFO}" > "${LOG}" 2>&1 &
LPID=$!

# helper to send a command to linphonec
lc() { echo "$*" > "${FIFO}"; }

# ---- wait for registration ----
echo "[linphone] waiting for registration ..."
for _ in $(seq 1 30); do
    sleep 2
    if grep -qiE "Registration.*successful|registered" "${LOG}"; then
        echo "[linphone] REGISTERED sip:${SIP_USER}@${SIP_DOMAIN}"
        break
    fi
done
grep -iE "regist" "${LOG}" | tail -3

# ---- caller: auto-dial ----
if [ -n "${PEER_URI}" ]; then
    echo "[linphone] waiting ${CALL_WAIT}s before calling ${PEER_URI} ..."
    sleep "${CALL_WAIT}"
    echo "[linphone] calling ${PEER_URI} ..."
    lc "call ${PEER_URI}"
fi

echo "[linphone] ready. Control with:"
echo "    docker exec <ctr> sh -c 'echo \"call sip:ue1@10.100.0.10\" > ${FIFO}'"
echo "    docker exec <ctr> sh -c 'echo terminate > ${FIFO}'"
echo "[linphone] tailing linphonec log ..."
tail -f "${LOG}"
