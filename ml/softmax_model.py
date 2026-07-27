#!/usr/bin/env python3
"""Tiny dependency-free multinomial logistic-regression model (numpy only).

Kept minimal on purpose: the lab's synthetic classes are well separated, so a
standardized softmax classifier is plenty — and it needs no scikit-learn download.
"""
import numpy as np


def softmax(Z):
    Z = Z - Z.max(axis=1, keepdims=True)
    E = np.exp(Z)
    return E / E.sum(axis=1, keepdims=True)


def fit(X, y_idx, n_classes, iters=4000, lr=0.5, l2=1e-3, seed=0):
    """X standardized (n,F); y_idx (n,) int labels. Returns (W, b)."""
    rng = np.random.default_rng(seed)
    n, F = X.shape
    W = rng.normal(0, 0.01, (F, n_classes))
    b = np.zeros(n_classes)
    Y = np.eye(n_classes)[y_idx]
    for _ in range(iters):
        P = softmax(X @ W + b)
        gW = X.T @ (P - Y) / n + l2 * W
        gb = (P - Y).mean(axis=0)
        W -= lr * gW
        b -= lr * gb
    return W, b


def standardize_params(X):
    mu = X.mean(axis=0)
    sd = X.std(axis=0)
    sd[sd == 0] = 1.0
    return mu, sd


def save(path, W, b, mu, sd, features, labels):
    np.savez(path, W=W, b=b, mu=mu, sd=sd,
             features=np.array(features, dtype=object).astype(str),
             labels=np.array(labels, dtype=object).astype(str))


def load(path):
    d = np.load(path, allow_pickle=False)
    return {
        "W": d["W"], "b": d["b"], "mu": d["mu"], "sd": d["sd"],
        "features": [str(x) for x in d["features"]],
        "labels": [str(x) for x in d["labels"]],
    }


def predict(model, X):
    Xn = (X - model["mu"]) / model["sd"]
    P = softmax(Xn @ model["W"] + model["b"])
    idx = P.argmax(axis=1)
    return [model["labels"][i] for i in idx], P
