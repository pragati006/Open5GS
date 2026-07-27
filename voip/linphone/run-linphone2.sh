#!/usr/bin/env bash
# linphonec runner with AUTO_ANSWER + explicit device selection, for a live
# linphonec<->linphonec call over 5G (native SIP interop; native pulse audio).
#
# Env:
#   SIP_USER/SIP_PASS/SIP_DOMAIN  identity + Kamailio
#   UE_IFACE                      5G tunnel iface
#   PEER_URI                      URI to auto-dial (caller); empty = callee
#   AUTO_ANSWER=yes               answer incoming calls automatically (callee)
#   CAPTURE_DEV / PLAYBACK_DEV    mediastreamer device ids
#                                 (default "PulseAudio: default"; "null" = none)
set -u
SIP_USER="${SIP_USER:?}"; SIP_PASS="${SIP_PASS:?}"; SIP_DOMAIN="${SIP_DOMAIN:?}"
UE_IFACE="${UE_IFACE:-oaitun_ue1}"
PEER_URI="${PEER_URI:-}"
CALL_WAIT="${CALL_WAIT:-15}"
AUTO_ANSWER="${AUTO_ANSWER:-no}"
CAPTURE_DEV="${CAPTURE_DEV:-PulseAudio: default}"
PLAYBACK_DEV="${PLAYBACK_DEV:-PulseAudio: default}"
RC=/root/.linphonerc
FIFO=/tmp/lin.in
LOG=/tmp/lin.log

echo "[lin2] waiting for ${UE_IFACE} ..."
UE_IP=""
for _ in $(seq 1 120); do
    UE_IP=$(ip -4 -o addr show dev "${UE_IFACE}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [ -n "${UE_IP}" ] && break
    sleep 2
done
[ -z "${UE_IP}" ] && { echo "[lin2] ERROR: ${UE_IFACE} no IP"; exit 1; }
echo "[lin2] UE IP=${UE_IP}"
ip route replace 10.100.0.0/24 dev "${UE_IFACE}"

# liblinphone needs its data/config dirs to exist or the core never reaches
# GlobalOn and rejects incoming calls with "503 (core global state not on)".
mkdir -p /root/.local/share/linphone /root/.config/linphone /root/.cache

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
playback_dev_id=${PLAYBACK_DEV}
capture_dev_id=${CAPTURE_DEV}
ringer_dev_id=${PLAYBACK_DEV}
echocancellation=1

[video]
display=0
capture=0
[net]
mtu=1300
EOF
echo "[lin2] rc written: capture='${CAPTURE_DEV}' playback='${PLAYBACK_DEV}' autoanswer=${AUTO_ANSWER}"

rm -f "${FIFO}"; mkfifo "${FIFO}"
sleep infinity > "${FIFO}" &
linphonec -c "${RC}" -d 3 < "${FIFO}" > "${LOG}" 2>&1 &
lc() { echo "$*" > "${FIFO}"; }

echo "[lin2] waiting for registration ..."
for _ in $(seq 1 30); do
    sleep 2
    grep -qiE "Registration.*successful|registered on|Refresher .*200" "${LOG}" && { echo "[lin2] REGISTERED"; break; }
done

# auto-answer watcher (callee)
if [ "${AUTO_ANSWER}" = "yes" ]; then
    echo "[lin2] auto-answer watcher on"
    (
        tail -n +1 -F "${LOG}" 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                *"New incoming call"*|*"Receiving new incoming call"*|*IncomingReceived*)
                    sleep 1; echo "answer" > "${FIFO}"; echo "[lin2] >>> answered" ;;
            esac
        done
    ) &
fi

# caller auto-dial
if [ -n "${PEER_URI}" ]; then
    echo "[lin2] waiting ${CALL_WAIT}s then dialling ${PEER_URI}"
    sleep "${CALL_WAIT}"
    lc "call ${PEER_URI}"
fi

echo "[lin2] ready; control: docker exec <ctr> sh -c 'echo <cmd> > ${FIFO}'"
tail -f "${LOG}"
