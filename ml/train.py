#!/usr/bin/env python3
"""Train the RTP loss-cause / QoS classifier from a windowed-feature CSV (numpy only)."""
import csv
import sys
import numpy as np
from rtp_features import FEATURES
import softmax_model as M


def load_csv(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    X = np.array([[float(r[c]) for c in FEATURES] for r in rows], float)
    y = [r["label"] for r in rows]
    return X, y


def stratified_split(y, test_frac=0.3, seed=0):
    rng = np.random.default_rng(seed)
    tr, te = [], []
    y = np.array(y)
    for lab in np.unique(y):
        idx = np.where(y == lab)[0]
        rng.shuffle(idx)
        k = max(1, int(round(len(idx) * test_frac)))
        te.extend(idx[:k])
        tr.extend(idx[k:])
    return np.array(tr), np.array(te)


def confusion(y_true, y_pred, labels):
    n = len(labels)
    ix = {l: i for i, l in enumerate(labels)}
    C = np.zeros((n, n), int)
    for t, p in zip(y_true, y_pred):
        C[ix[t], ix[p]] += 1
    return C


def main():
    csv_path = sys.argv[1] if len(sys.argv) > 1 else "data/dataset.csv"
    X, y = load_csv(csv_path)
    labels = sorted(set(y))
    lab_ix = {l: i for i, l in enumerate(labels)}
    yi = np.array([lab_ix[v] for v in y])

    print("=== class balance ===")
    for l in labels:
        print(f"  {l:11s} {y.count(l)}")

    tr, te = stratified_split(y)
    mu, sd = M.standardize_params(X[tr])
    Xtr = (X[tr] - mu) / sd
    W, b = M.fit(Xtr, yi[tr], len(labels))

    model = {"W": W, "b": b, "mu": mu, "sd": sd, "features": FEATURES, "labels": labels}
    pred_tr, _ = M.predict(model, X[tr])
    pred_te, _ = M.predict(model, X[te])
    acc_tr = np.mean(np.array(pred_tr) == np.array(y)[tr])
    acc_te = np.mean(np.array(pred_te) == np.array(y)[te])

    print(f"\ntrain accuracy: {acc_tr:.3f}   held-out accuracy: {acc_te:.3f}")
    print("\n=== confusion matrix (held-out; rows=true, cols=pred) ===")
    print("labels:", labels)
    print(confusion(np.array(y)[te], pred_te, labels))

    imp = np.abs(W).mean(axis=1)   # standardized-weight magnitude ~ importance
    order = np.argsort(imp)[::-1]
    print("\n=== top discriminating features ===")
    for i in order[:8]:
        print(f"  {FEATURES[i]:20s} {imp[i]:.3f}")

    M.save("model.npz", W, b, mu, sd, FEATURES, labels)
    print("\nsaved model.npz")


if __name__ == "__main__":
    main()
