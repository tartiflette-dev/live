#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Scan de PEM anti-eMudhra : deux racines retirées après la compromission
d'intermédiaires eMudhra (octobre 2026) ne doivent plus figurer dans l'image.

Prend en argv un ou plusieurs chemins de bundles PEM (cacert.pem, ca-certificates.crt, …).
Exit 0 si AUCUN n'embarque une des deux racines compromises :
  - emSign ECC Root CA - G3 (sha256 DER 86A1ECBA…BE6B)
  - AAA Certificate Services (sha256 DER D7A7A0FB…9EF4)
Exit 1 et détail sur stderr sinon.

Pensé pour tourner comme sonde de build (RUN find … | xargs scan) et comme sonde
post-déploiement sur un conteneur.
"""
import base64
import hashlib
import re
import sys

BAD = {
    "86A1ECBA089C4A8D3BBE2734C612BA341D813E043CF9E8A862CD5C57A36BBE6B": "emSign-ECC-G3",
    "D7A7A0FB5D7E2731D771E9484EBCDEF71D5F0C3E0A2948782BC83EE0EA699EF4": "AAA",
}
PEM_RE = re.compile(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", re.S)


def scan(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        print(f"{path}: unreadable ({e})", file=sys.stderr)
        return []
    hits = []
    for b64 in PEM_RE.findall(text):
        der = base64.b64decode("".join(b64.split()))
        digest = hashlib.sha256(der).hexdigest().upper()
        if digest in BAD:
            hits.append(BAD[digest])
    return hits


def main(argv):
    bad = 0
    for p in argv:
        hits = scan(p)
        if hits:
            print(f"FAIL eMudhra: {p} -> {','.join(hits)}", file=sys.stderr)
            bad += 1
    if bad:
        return 1
    print(f"OK eMudhra: {len(argv)} fichier(s) propre(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
