#!/usr/bin/env bash
# Provision the two test UEs into the Open5GS subscriber DB (MongoDB).
# Runs inside an image that ships `open5gs-dbctl` (gradiant/open5gs-dbctl).
#
# Both UEs share the standard OAI test credentials (K/OPc). Only the IMSI
# differs. open5gs-dbctl's "add" gives each subscriber a default profile with
# slice SST=1 and DNN "internet", which matches the SMF/UPF session config.
set -euo pipefail

export DB_URI="${DB_URI:-mongodb://mongo/open5gs}"

KEY="fec86ba6eb707ed08905757b1bb44b8f"
OPC="C42449363BBAD02B66D16BC975D77CC1"

UES=(
  "001010000000001"
  "001010000000002"
)

echo "[dbctl] using DB_URI=${DB_URI}"

# wait for mongo
for _ in $(seq 1 60); do
  if open5gs-dbctl showall >/dev/null 2>&1; then break; fi
  echo "[dbctl] waiting for mongo ..."
  sleep 2
done

for IMSI in "${UES[@]}"; do
  echo "[dbctl] removing any existing subscriber ${IMSI}"
  open5gs-dbctl remove "${IMSI}" >/dev/null 2>&1 || true
  echo "[dbctl] adding subscriber ${IMSI}"
  open5gs-dbctl add "${IMSI}" "${KEY}" "${OPC}"
done

echo "[dbctl] current subscribers:"
open5gs-dbctl showfiltered || open5gs-dbctl showall || true
echo "[dbctl] done"
