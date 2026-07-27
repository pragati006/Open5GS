#!/usr/bin/env bash
# Headless baresip v1.0.0 runner (OTT SIP over 5G data plane).
#
# Env vars (docker-compose.sip.yaml):
#   SIP_USER, SIP_PASS, SIP_DOMAIN  – SIP identity + Kamailio address
#   UE_IFACE                        – 5G tunnel iface (oaitun_ue1)
#   PEER_URI                        – URI to call (caller only; empty = callee)
#   CALL_WAIT                       – s to wait before dialling (default 30)
#   CALL_HOLD                       – s to keep the call up (default 25)
set -u

SIP_USER="${SIP_USER:?}"; SIP_PASS="${SIP_PASS:?}"; SIP_DOMAIN="${SIP_DOMAIN:?}"
UE_IFACE="${UE_IFACE:-oaitun_ue1}"
PEER_URI="${PEER_URI:-}"
CALL_WAIT="${CALL_WAIT:-30}"
CALL_HOLD="${CALL_HOLD:-25}"
CFGDIR="/etc/baresip"
CTRL="python3 /baresip-ctrl.py"

# Audio config (defaults = headless tone file; override for mic/echo modes)
AUDIO_SOURCE="${AUDIO_SOURCE:-aufile,/opt/test.wav}"
AUDIO_PLAYER="${AUDIO_PLAYER:-aufile,/opt/test.wav}"
EXTRA_MODULES="${EXTRA_MODULES:-}"

# ---- wait for the 5G tunnel ----
echo "[baresip] waiting for ${UE_IFACE} ..."
UE_IP=""
for _ in $(seq 1 120); do
    UE_IP=$(ip -4 -o addr show dev "${UE_IFACE}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [ -n "${UE_IP}" ] && break
    sleep 2
done
[ -z "${UE_IP}" ] && { echo "[baresip] ERROR: ${UE_IFACE} no IP"; exit 1; }
echo "[baresip] UE data-plane IP = ${UE_IP}"

# ---- force Kamailio/RTP through the 5G tunnel ----
ip route replace 10.100.0.0/24 dev "${UE_IFACE}"
echo "[baresip] route 10.100.0.0/24 -> ${UE_IFACE} OK"

# ---- account (auto-answer so the callee picks up automatically) ----
mkdir -p "${CFGDIR}"
cat > "${CFGDIR}/accounts" <<EOF
<sip:${SIP_USER}@${SIP_DOMAIN}>;auth_pass=${SIP_PASS};outbound="sip:${SIP_DOMAIN}";regint=60;answermode=auto;audio_codecs=PCMU/8000,PCMA/8000
EOF
echo "[baresip] account: sip:${SIP_USER}@${SIP_DOMAIN} (answermode=auto)"

# ---- bind SIP to the UE IP ----
sed -i "s|^sip_listen.*|sip_listen\t\t${UE_IP}:5080|" "${CFGDIR}/config"

# ---- audio source/player (mic/echo modes override the defaults) ----
sed -i "s|^audio_source.*|audio_source\t\t${AUDIO_SOURCE}|" "${CFGDIR}/config"
sed -i "s|^audio_player.*|audio_player\t\t${AUDIO_PLAYER}|" "${CFGDIR}/config"
for m in ${EXTRA_MODULES}; do
    echo "module ${m}" >> "${CFGDIR}/config"
    echo "[baresip] extra module: ${m}"
done
echo "[baresip] audio: source='${AUDIO_SOURCE}' player='${AUDIO_PLAYER}'"

# ---- start baresip daemon ----
echo "[baresip] starting baresip ..."
baresip -f "${CFGDIR}" -d -p /opt 2>/tmp/baresip.log
sleep 4

# ---- confirm registration via ctrl_tcp ----
echo "[baresip] checking registration ..."
for i in $(seq 1 30); do
    if ${CTRL} reginfo 2>/dev/null | grep -qiE "\"ua\"|registered|${SIP_USER}"; then
        echo "[baresip] registration query returned data (attempt $i)"
        break
    fi
    sleep 2
done
echo "[baresip] reginfo: $(${CTRL} reginfo 2>/dev/null | tr -d '\n' | head -c 200)"

# ---- caller: place the call ----
if [ -n "${PEER_URI}" ]; then
    echo "[baresip] (caller) waiting ${CALL_WAIT}s for peer to register ..."
    sleep "${CALL_WAIT}"
    echo "[baresip] dialling ${PEER_URI} ..."
    ${CTRL} dial "${PEER_URI}"
    sleep 5
    echo "[baresip] active calls after dial:"
    ${CTRL} listcalls
    echo "[baresip] holding call for ${CALL_HOLD}s (media flowing via RTPengine) ..."
    sleep "${CALL_HOLD}"
    echo "[baresip] hanging up ..."
    ${CTRL} hangup
    echo "[baresip] call sequence complete"
fi

echo "[baresip] alive — control with: docker exec <ctr> python3 /baresip-ctrl.py <cmd> [param]"
tail -f /dev/null
