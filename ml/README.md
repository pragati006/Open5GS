# RTP loss-cause / QoS classifier

An ML component that reads **RTP statistics** from the 5G data plane and classifies
the *cause* of media degradation, so the right mitigation can be chosen:

| Predicted class | User-plane cause | Correct mitigation |
|---|---|---|
| `clean` | link healthy | none |
| `radio` | random/bursty link loss (radio BLER, no queue growth) | **add FEC / RTP redundancy + PLC** (do *not* cut bitrate) |
| `congestion` | queue builds → delay/jitter rise, then loss | **reduce bitrate / lower-rate codec** (do *not* add FEC) |

The two causes need *opposite* fixes, so a threshold isn't enough — hence a classifier.

## How it works
The discriminating insight is **timing**: congestion makes packets *queue*
(one-way delay + jitter climb) before they drop; random radio loss drops packets
*without* delay growth and tends to be bursty. `rtp_features.py` turns a pcap into
per-second feature rows capturing exactly that:

- `owd_slope_ms_per_s`, `owd_range_ms` — one-way-delay trend (congestion signal)
- `jitter_mean_ms`, `jitter_max_ms`, `ia_std_ms` — jitter / arrival spread
- `loss_rate`, `burst_mean_len`, `burst_frac`, `reorder_rate` — loss amount & pattern
- `pps`, `kbps` — load (congestion shaping drops the rate)

It analyses the stream **received from the RTPengine relay** (`src 10.100.0.11`),
i.e. downstream of the impaired leg — the realistic measurement point.

## Dependency-light
Pure **standard library + numpy** (already on the host). pcap/IP/UDP/RTP are parsed
by hand; the model is a small numpy softmax classifier (`softmax_model.py`). No
scikit-learn / dpkt / Docker downloads required.

## Files
```
rtp_features.py    pcap -> per-window feature CSV (stdlib pcap parser + numpy)
softmax_model.py   tiny numpy multinomial logistic-regression (fit/save/load/predict)
train.py           train + evaluate (accuracy, confusion matrix, feature importance)
predict.py         score a pcap -> per-window class, verdict, recommended mitigation
data/              labelled pcaps (<label>[-n].pcap) + generated dataset.csv
model.npz          trained model (after training)
```

## Use
```bash
bash scripts/rtp-dataset.sh          # 1) generate labelled data over 5G (tc netem+tbf)
bash scripts/rtp-train.sh            # 2) extract features + train + evaluate (host python3)
cd ml && python3 predict.py data/congestion.pcap    # 3) classify + get mitigation
bash scripts/dbg-pcap.sh             # (debug) per-pcap link/RTP/direction breakdown
```

## Labels come free
`scripts/rtp-dataset.sh` uses `tc` on the caller's tunnel to *manufacture* each class
(`netem loss 7% 30%` = radio; `tbf rate 56kbit` below the media bitrate = congestion)
and captures at the callee — no manual annotation. Establishing the call *before*
applying the impairment keeps SIP setup clean.

## Result (72 windows, 24/class)
Held-out accuracy ≈ 0.76; **congestion vs radio is cleanly separated** (the decision
that matters): congestion 23/24 and radio 20/24 windows classified correctly, with no
congestion↔radio cross-confusion. Residual error is `clean`↔`radio` (mild 7% bursty
loss looks near-healthy) — improve by capturing more/stronger scenarios or widening
the window. Top features: `jitter_max_ms`, `kbps`, `pps`, `reorder_rate`,
`burst_mean_len`, `owd_range_ms`.

## Where it plugs in
This is the classifier from the QoS-mitigation discussion: its output selects the
actuator — **add FEC** (radio) vs **reduce rate** (congestion). Pair it with RAN
metrics (HARQ/BLER) for a ground-truth radio-loss label when available.
