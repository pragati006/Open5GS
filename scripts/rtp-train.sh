#!/usr/bin/env bash
# Extract features from every labelled pcap in ml/data/, then train + evaluate the
# loss-cause classifier. Runs on the host Python (numpy only — no downloads).
# Label = pcap filename before the first '-'  (e.g. congestion.pcap, radio-2.pcap).
set -eu
cd /home/pragati/linux_workspace/Open5GS/ml
rm -f data/dataset.csv
shopt -s nullglob
found=0
for f in data/*.pcap; do
    found=1
    label="$(basename "$f" .pcap | cut -d- -f1)"
    python3 rtp_features.py "$f" --label "$label" --relay-ip "${RELAY_IP:-10.100.0.11}" --out data/dataset.csv
done
[ "$found" = 1 ] || { echo "no pcaps in ml/data/ — run scripts/rtp-dataset.sh first"; exit 1; }
echo "=== dataset rows ==="; wc -l data/dataset.csv
python3 train.py data/dataset.csv
echo "model -> ml/model.npz ; dataset -> ml/data/dataset.csv"
