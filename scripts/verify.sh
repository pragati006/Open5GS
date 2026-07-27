#!/usr/bin/env bash
# End-to-end verification of the Open5GS + OAI 5G setup.
#   1. both UEs registered on the AMF
#   2. both UEs got a data-plane IP (oaitun_ue1) from the core
#   3. SIP dialogs completed through the 5G data plane
set -uo pipefail
cd "$(dirname "$0")/.."

DC="docker compose"
pass=0; fail=0
ok()   { echo "  [PASS] $1"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $1"; fail=$((fail+1)); }

echo "=== 1. UE registration on AMF ==="
amf_log="$($DC logs amf 2>/dev/null)"
for imsi in 001010000000001 001010000000002; do
  if echo "$amf_log" | grep -q "imsi-${imsi}"; then
    ok "AMF saw subscriber imsi-${imsi}"
  else
    bad "AMF has no trace of imsi-${imsi}"
  fi
done
reg_cnt="$(echo "$amf_log" | grep -c 'Registration complete')"
echo "  (AMF 'Registration complete' events: ${reg_cnt})"
[ "${reg_cnt}" -ge 2 ] && ok "at least 2 registrations completed" \
                        || bad "fewer than 2 registrations completed"

echo "=== 2. UE data-plane IP (oaitun_ue1) ==="
for ue in oai-nr-ue-1 oai-nr-ue-2; do
  ip="$(docker exec "$ue" bash -c 'ip -4 -o addr show dev oaitun_ue1 2>/dev/null | awk "{print \$4}"' 2>/dev/null)"
  if [ -n "$ip" ]; then ok "$ue oaitun_ue1 = $ip"; else bad "$ue has no oaitun_ue1 IP"; fi
done

echo "=== 3. IP connectivity + SIP through the 5G data plane ==="
for c in sip-client-1 sip-client-2; do
  clog="$($DC logs "$c" 2>/dev/null)"
  echo "$clog" | grep -q "ping OK" && ok "$c: ping through core OK" \
                                    || bad "$c: ping through core not confirmed"
  if echo "$clog" | grep -q "SUCCESS: SIP dialog"; then
    ok "$c: SIP dialog completed over 5G data plane"
  else
    bad "$c: SIP dialog not confirmed (see: docker compose logs $c)"
  fi
done

echo
echo "=== SUMMARY: ${pass} passed, ${fail} failed ==="
[ "$fail" -eq 0 ]
