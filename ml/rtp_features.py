#!/usr/bin/env python3
"""
Extract per-window RTP features from a pcap, for the loss-cause / QoS classifier.

Dependency-light: standard library pcap/IP/UDP/RTP parsing + numpy only
(no dpkt / pandas needed, so it runs on the host without downloads).

We analyse the RTP stream RECEIVED from the relay (default src = RTPengine
10.100.0.11) — the downstream stream that has traversed the impaired 5G leg —
group by SSRC, and compute per-window features that separate:

  * congestion loss  -> queue builds first: one-way-delay (OWD) proxy and jitter
                        rise before loss  => owd_slope > 0, high jitter
  * random radio loss-> bit errors drop packets without queue growth
                        => owd_slope ~ 0, bursty loss, flat delay
  * clean            -> low loss, low jitter, flat delay

CLI:
  rtp_features.py CAP.pcap --label congestion --out data/dataset.csv
  rtp_features.py CAP.pcap                      # print CSV to stdout (no label)
"""
import argparse
import csv
import os
import struct
import sys
import numpy as np

FEATURES = [
    "pps", "kbps", "loss_rate", "reorder_rate",
    "jitter_mean_ms", "jitter_max_ms", "ia_mean_ms", "ia_std_ms",
    "owd_slope_ms_per_s", "owd_range_ms", "burst_mean_len", "burst_frac",
]
WINDOW = 1.0
MIN_PKTS = 20
DEFAULT_CLOCK = 8000.0


# ------------------------- stdlib pcap / IP / UDP parsing -------------------------
def _iter_packets(path):
    """Yield (t_epoch, linktype, raw_frame) from a classic pcap file."""
    with open(path, "rb") as f:
        gh = f.read(24)
        if len(gh) < 24:
            return
        magic = gh[:4]
        if magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
            endian, nano = ">", magic == b"\xa1\xb2\x3c\x4d"
        elif magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
            endian, nano = "<", magic == b"\x4d\x3c\xb2\xa1"
        else:
            raise SystemExit(f"not a pcap file: {path}")
        linktype = struct.unpack(endian + "I", gh[20:24])[0]
        while True:
            rh = f.read(16)
            if len(rh) < 16:
                break
            ts_sec, ts_frac, incl, _orig = struct.unpack(endian + "IIII", rh)
            data = f.read(incl)
            if len(data) < incl:
                break
            t = ts_sec + ts_frac / (1e9 if nano else 1e6)
            yield t, linktype, data


def _ip_offset(frame, linktype):
    """Return offset of the IPv4 header within the frame, or None."""
    if linktype == 1:            # EN10MB
        if len(frame) >= 14 and frame[12:14] == b"\x08\x00":
            return 14
        return None
    if linktype in (12, 101):    # RAW IP
        return 0
    if linktype == 113:          # LINUX_SLL
        return 16
    if linktype == 276:          # LINUX_SLL2
        return 20
    for off in (0, 14, 16, 20):  # fallback: find an IPv4 header
        if len(frame) > off and (frame[off] >> 4) == 4:
            return off
    return None


def _parse_udp(frame, linktype):
    """Return (src_ip_str, udp_payload_bytes) for UDP/IPv4 frames, else None."""
    off = _ip_offset(frame, linktype)
    if off is None or len(frame) < off + 20:
        return None
    b0 = frame[off]
    if (b0 >> 4) != 4:
        return None
    ihl = (b0 & 0x0F) * 4
    proto = frame[off + 9]
    if proto != 17:               # UDP
        return None
    src = ".".join(str(x) for x in frame[off + 12:off + 16])
    udp = off + ihl
    if len(frame) < udp + 8:
        return None
    payload = frame[udp + 8:]
    return src, payload


def _parse_rtp(p):
    if len(p) < 12 or (p[0] >> 6) != 2:
        return None
    b1 = p[1]
    if 200 <= b1 <= 204:          # RTCP
        return None
    seq = struct.unpack("!H", p[2:4])[0]
    ts = struct.unpack("!I", p[4:8])[0]
    ssrc = struct.unpack("!I", p[8:12])[0]
    return seq, ts, ssrc


# ------------------------------ feature computation ------------------------------
def _load_stream(path, relay_ip):
    by_ssrc = {}
    for t, linktype, frame in _iter_packets(path):
        udp = _parse_udp(frame, linktype)
        if udp is None:
            continue
        src, payload = udp
        if relay_ip and src != relay_ip:
            continue
        rtp = _parse_rtp(payload)
        if rtp is None:
            continue
        seq, ts, ssrc = rtp
        by_ssrc.setdefault(ssrc, []).append((t, seq, ts, len(payload)))
    if not by_ssrc:
        return None
    ssrc = max(by_ssrc, key=lambda s: len(by_ssrc[s]))
    return sorted(by_ssrc[ssrc], key=lambda x: x[0])


def _unwrap(seqs):
    out, offset, prev = [], 0, None
    for s in seqs:
        if prev is not None:
            d = s - prev
            if d < -32768:
                offset += 65536
            elif d > 32768:
                offset -= 65536
        out.append(s + offset)
        prev = s
    return out


def _burst_stats(present_sorted):
    lo, hi = present_sorted[0], present_sorted[-1]
    present = set(present_sorted)
    missing = [s for s in range(lo, hi + 1) if s not in present]
    if not missing:
        return 0.0, 0.0
    runs, cur = [], 1
    for i in range(1, len(missing)):
        if missing[i] == missing[i - 1] + 1:
            cur += 1
        else:
            runs.append(cur)
            cur = 1
    runs.append(cur)
    return float(np.mean(runs)), float(sum(r for r in runs if r > 1)) / len(missing)


def _windows(rows, clock=DEFAULT_CLOCK):
    t0 = rows[0][0]
    buckets = {}
    for (t, seq, ts, size) in rows:
        buckets.setdefault(int((t - t0) // WINDOW), []).append((t, seq, ts, size))

    for w in sorted(buckets):
        pk = buckets[w]
        if len(pk) < MIN_PKTS:
            continue
        ts_arr = np.array([p[0] for p in pk], float)
        rtp_ts = np.array([p[2] for p in pk], float)
        sizes = np.array([p[3] for p in pk], float)
        seqs_u = _unwrap([p[1] for p in pk])

        dur = max(ts_arr[-1] - ts_arr[0], 1e-3)
        pps = len(pk) / dur
        kbps = sizes.sum() * 8.0 / dur / 1000.0

        lo, hi = min(seqs_u), max(seqs_u)
        expected = hi - lo + 1
        received = len(set(seqs_u))
        loss_rate = max(0.0, (expected - received) / expected)
        reorder = sum(1 for i in range(1, len(seqs_u)) if seqs_u[i] < seqs_u[i - 1])
        reorder_rate = reorder / len(seqs_u)

        ia = np.diff(ts_arr)
        ia_mean = float(ia.mean()) * 1000.0 if ia.size else 0.0
        ia_std = float(ia.std()) * 1000.0 if ia.size else 0.0

        transit = ts_arr - rtp_ts / clock          # one-way-delay proxy (arbitrary offset)
        jit, jits = 0.0, []
        for i in range(1, len(transit)):
            jit += (abs(transit[i] - transit[i - 1]) - jit) / 16.0
            jits.append(jit)
        jitter_mean = float(np.mean(jits)) * 1000.0 if jits else 0.0
        jitter_max = float(np.max(jits)) * 1000.0 if jits else 0.0

        rel_t = ts_arr - ts_arr[0]
        owd = transit - transit.min()
        slope = float(np.polyfit(rel_t, owd, 1)[0]) * 1000.0 if rel_t[-1] > 0 else 0.0
        owd_range = float(owd.max() - owd.min()) * 1000.0

        burst_mean_len, burst_frac = _burst_stats(sorted(seqs_u))

        yield [pps, kbps, loss_rate, reorder_rate, jitter_mean, jitter_max,
               ia_mean, ia_std, slope, owd_range, burst_mean_len, burst_frac]


def extract_rows(path, relay_ip="10.100.0.11"):
    """Return list of feature-value lists (one per window), aligned to FEATURES."""
    rows = _load_stream(path, relay_ip)
    if not rows:
        return []
    return list(_windows(rows))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pcap")
    ap.add_argument("--label", default=None)
    ap.add_argument("--relay-ip", default="10.100.0.11")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    recs = extract_rows(args.pcap, relay_ip=args.relay_ip)
    if not recs:
        raise SystemExit(f"no RTP windows in {args.pcap} (src={args.relay_ip})")

    header = FEATURES + (["label"] if args.label is not None else [])
    out_rows = [r + ([args.label] if args.label is not None else []) for r in recs]

    if args.out:
        new = not os.path.exists(args.out) or os.path.getsize(args.out) == 0
        with open(args.out, "a", newline="") as f:
            wr = csv.writer(f)
            if new:
                wr.writerow(header)
            wr.writerows(out_rows)
        print(f"{args.pcap}: +{len(recs)} windows -> {args.out}")
    else:
        wr = csv.writer(sys.stdout)
        wr.writerow(header)
        wr.writerows(out_rows)


if __name__ == "__main__":
    main()
