#!/usr/bin/env python3
"""Score a pcap with the trained loss-cause classifier and recommend a mitigation.

Usage: predict.py CAP.pcap [relay_ip]
"""
import collections
import sys
import numpy as np
from rtp_features import extract_rows, FEATURES
import softmax_model as M

ACTIONS = {
    "clean":      "no action (link healthy)",
    "radio":      "ADD FEC / RTP redundancy (RED) + enable PLC  — do NOT cut bitrate",
    "congestion": "REDUCE sending bitrate / switch to a lower-rate codec  — do NOT add FEC",
}


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: predict.py CAP.pcap [relay_ip]")
    pcap = sys.argv[1]
    relay = sys.argv[2] if len(sys.argv) > 2 else "10.100.0.11"

    model = M.load("model.npz")
    recs = extract_rows(pcap, relay_ip=relay)
    if not recs:
        raise SystemExit("no RTP windows found")

    X = np.array(recs, float)
    preds, _ = M.predict(model, X)
    counts = collections.Counter(preds)
    verdict = counts.most_common(1)[0][0]

    print(f"windows analysed : {len(recs)}")
    print(f"per-window class : {dict(counts)}")
    print(f"call verdict     : {verdict}")
    print(f"recommended fix  : {ACTIONS.get(verdict, '?')}")


if __name__ == "__main__":
    main()
