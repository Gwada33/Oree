#!/usr/bin/env python3
"""Hôte de messagerie native d'essai : répond {"echo": message, "origin": argv[1]} à chaque message (4 octets de longueur + JSON)."""
import json, struct, sys
while True:
    head = sys.stdin.buffer.read(4)
    if len(head) < 4: break
    msg = json.loads(sys.stdin.buffer.read(struct.unpack('=I', head)[0]))
    out = json.dumps({"echo": msg, "origin": sys.argv[1] if len(sys.argv) > 1 else ""}).encode()
    sys.stdout.buffer.write(struct.pack('=I', len(out)) + out); sys.stdout.buffer.flush()
