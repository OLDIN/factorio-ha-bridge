#!/usr/bin/env python3
"""Print every datagram the factorio-ha mod sends (stdlib only). Usage: udp-dump.py [port]"""

import socket
import sys

port = int(sys.argv[1]) if len(sys.argv) > 1 else 34199
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind(("127.0.0.1", port))
    print(f"listening on udp://127.0.0.1:{port}", flush=True)
    while True:
        data, _ = sock.recvfrom(65535)
        print(data.decode(errors="replace"), flush=True)
