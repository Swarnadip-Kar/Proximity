#!/usr/bin/env python3
"""Rotation watch for Android key-attestation pins.

Compares Google's published attestation roots against the pins in
packages/protocol/lib/src/device_binding.dart and reports drift:

  * a published cert whose KEY is SPKI-pinned  -> covered, no action
    (same-key renewals like the 2019/2021 f92009 vintages match forever)
  * a published cert with an UNPINNED key       -> NEW ROOT KEY: pin it
    (this is what a future rotation looks like; devices chaining to it
    would fail enrollment as unknown-root until pinned)
  * a pinned cert-hash Google no longer publishes -> retained vintage
    (expected: Google delists old vintages; field devices keep them)

Sources (authoritative, Google-published):
  DOCS_PAGE = developer.android.com root-certificates section (full
              trustable vintage set; the live endpoint serves newest only)
  ENDPOINT  = https://android.googleapis.com/attestation/root (JSON PEMs)

Usage:
  python3 packages/protocol/tool/audit_attestation_roots.py

Exit: 0 covered/in-sync, 1 drift (new unpinned key), 2 error.
Needs: python3 stdlib + `openssl` CLI + network.
"""

import base64
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import os
import urllib.request

DOCS_PAGE = ("https://developer.android.com/privacy-and-security/"
             "security-key-attestation")
ENDPOINT = "https://android.googleapis.com/attestation/root"
DEVICE_BINDING = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "..", "lib", "src", "device_binding.dart")
TIMEOUT = 30


def fetch_text(url):
    req = urllib.request.Request(url, headers={"User-Agent": "proximity-audit/1"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        raw = r.read()
    if url == ENDPOINT:
        pems = json.loads(raw.decode("utf-8"))
        if not isinstance(pems, list) or not all(isinstance(p, str) for p in pems):
            raise ValueError("endpoint: expected JSON array of PEM strings")
        return pems
    html = raw.decode("utf-8", errors="replace")
    pems = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
                      html, re.S)
    return [p.strip() for p in pems]


def pem_der(pem):
    body = "".join(l.strip() for l in pem.splitlines() if "CERTIFICATE" not in l)
    return base64.b64decode(body)


def openssl_text(der):
    with tempfile.NamedTemporaryFile(suffix=".der", delete=False) as f:
        f.write(der)
        path = f.name
    try:
        def run(*args):
            return subprocess.run(["openssl", "x509", "-inform", "DER",
                                   "-in", path, *args],
                                  capture_output=True, text=True,
                                  timeout=TIMEOUT).stdout.strip()
        info = run("-noout", "-subject", "-serial", "-dates").replace("\n", " | ")
        pub = subprocess.run(["openssl", "x509", "-inform", "DER", "-in", path,
                              "-noout", "-pubkey"],
                             capture_output=True, text=True,
                             timeout=TIMEOUT).stdout
        spki = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"],
                              input=pub.encode(), capture_output=True,
                              timeout=TIMEOUT).stdout
        return info, hashlib.sha256(der).hexdigest(), \
            hashlib.sha256(spki).hexdigest()
    finally:
        os.unlink(path)


def pinned_hashes():
    flat = open(DEVICE_BINDING, encoding="utf-8").read().replace("\n", " ")
    certs = set()
    for m in re.finditer(
            r"(kGoogleHwAttestationRoot\w*)\s*=\s*'\s*([0-9a-f]{64})\s*'",
            flat):
        # Rsa2016Hex is diagnostics-only (expired-cert copy), never in the
        # gate's pin list — exclude so the report reflects real trust.
        if "Rsa2016" not in m.group(1):
            certs.add(m.group(2))
    spki = set()
    for m in re.finditer(
            r"(kGoogleHwAttestation\w*SpkiSha256Hex)\s*=\s*'([0-9a-f]{64})\s*'",
            flat):
        spki.add(m.group(2))
    return certs, spki


def main():
    if shutil.which("openssl") is None:
        print("ERROR: `openssl` CLI not found.")
        return 2
    try:
        docs_pems = fetch_text(DOCS_PAGE)
        endpoint_pems = fetch_text(ENDPOINT)
    except Exception as e:  # noqa: BLE001 - report, never traceback
        print(f"ERROR: fetch failed: {e}")
        return 2
    if not docs_pems:
        print("ERROR: docs page yielded zero certificates.")
        return 2
    if not endpoint_pems:
        print("ERROR: endpoint yielded zero certificates.")
        return 2
    pinned_certs, pinned_spki = pinned_hashes()
    if not pinned_certs or not pinned_spki:
        print("ERROR: could not parse pins from device_binding.dart "
              f"(certs={len(pinned_certs)} spki={len(pinned_spki)}).")
        return 2

    seen = set()
    published = []  # (source, cert_hash, spki_hash, info)
    for source, pems in (("docs", docs_pems), ("endpoint", endpoint_pems)):
        for pem in pems:
            try:
                der = pem_der(pem)
            except Exception:  # noqa: BLE001
                print(f"WARN: [{source}] unparseable PEM block, skipped.")
                continue
            ch = hashlib.sha256(der).hexdigest()
            if ch in seen:
                continue
            seen.add(ch)
            try:
                info, ch2, sh = openssl_text(der)
            except Exception as e:  # noqa: BLE001
                print(f"WARN: [{source}] openssl failed: {e}")
                continue
            published.append((source, ch2, sh, info))

    print(f"published roots: {len(published)} "
          f"(docs={sum(1 for p in published if p[0]=='docs')}, "
          f"endpoint={sum(1 for p in published if p[0]=='endpoint')})")
    print(f"pinned: {len(pinned_certs)} cert hashes, "
          f"{len(pinned_spki)} SPKI key hashes\n")

    drift = 0
    for source, ch, sh, info in published:
        if ch in pinned_certs:
            status = "PINNED (cert)"
        elif sh in pinned_spki:
            status = "COVERED (key pin — same-key vintage, no action)"
        else:
            status = "*** NEW KEY — pin it (devices chaining here fail) ***"
            drift = 1
        print(f"[{source}] {ch[:8]} spki={sh[:8]} {status}\n"
              f"         {info}")
    print()
    for ch in sorted(pinned_certs):
        if not any(p[1] == ch for p in published):
            print(f"(retained) pinned cert {ch[:8]} not published by Google "
                  f"— old vintage, keep while field devices chain to it.")
    return drift


if __name__ == "__main__":
    sys.exit(main())
