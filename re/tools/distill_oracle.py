#!/usr/bin/env python3
"""Distill MQELOffline.log into a structured protocol record. v2

Log grammar (chronological, append-only, no dates):
  [I][HH:MM:SS] RE tls sock=N established ...
  [I][HH:MM:SS] RE rx sock=N len=L off=O hex=...   (off = offset within the CURRENT REQUEST)
  [I][HH:MM:SS] onPOST: /Service.hqs/Method
Session blocks are separated where the wall-clock timestamp jumps backwards
(server restarts). Requests are framed by Content-Length; multiple requests
share one keep-alive connection.
"""
import json
import re
import sys
from collections import OrderedDict

RX = re.compile(r"^\[I\]\[(\d\d:\d\d:\d\d)\] RE rx sock=(\d+) len=(\d+) off=(\d+) hex=([0-9a-f]*)")
TLS = re.compile(r"^\[I\]\[(\d\d:\d\d:\d\d)\] RE tls sock=(\d+) established")


def to_sec(t):
    h, m, s = t.split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


class Stream:
    """One keep-alive connection (a socket generation)."""

    __slots__ = ("ts0", "sock", "buf", "requests")

    def __init__(self, ts, sock):
        self.ts0 = ts
        self.sock = sock
        self.buf = bytearray()
        self.requests = []

    def feed(self, off, data):
        # a fragment at off==0 after a complete request starts a new request;
        # the framing parser below consumes completed requests greedily, so
        # simply ensure capacity and place.
        end = off + len(data)
        if len(self.buf) < end:
            self.buf.extend(b"\x00" * (end - len(self.buf)))
        self.buf[off:end] = data
        self.parse()

    def parse(self):
        while True:
            sep = self.buf.find(b"\r\n\r\n")
            if sep < 0:
                return
            head = self.buf[:sep].decode("utf-8", "replace")
            clen = 0
            for hl in head.split("\r\n")[1:]:
                if ":" in hl:
                    k, v = hl.split(":", 1)
                    if k.strip().lower() == "content-length":
                        clen = int(v.strip())
            total = sep + 4 + clen
            if len(self.buf) < total:
                return  # incomplete; wait for more fragments
            raw = bytes(self.buf[:total])
            del self.buf[:total]
            self.requests.append(raw)


def main(path):
    # ---- pass 1: chronological events ----
    events = []  # (kind, ts, sock, payload)
    last_t = None
    block_idx = 0
    for line in open(path, encoding="utf-8", errors="replace"):
        m = TLS.match(line)
        if m:
            t, s = to_sec(m.group(1)), int(m.group(2))
            if last_t is not None and t < last_t - 60:  # backwards > 1min => new server run
                block_idx += 1
            last_t = t
            events.append(("tls", t, block_idx, s, None))
            continue
        m = RX.match(line)
        if m:
            t, s = to_sec(m.group(1)), int(m.group(2))
            ln, off, hx = int(m.group(3)), int(m.group(4)), m.group(5)
            if last_t is not None and t < last_t - 60:
                block_idx += 1
            last_t = t
            events.append(("rx", t, block_idx, s, (off, bytes.fromhex(hx))))
            continue

    # ---- pass 2: streams keyed by (block, sock); 'tls' opens a new generation ----
    streams = OrderedDict()  # (block, sock, gen) -> Stream
    gens = {}
    for ev in events:
        kind, t, blk, sock, payload = ev
        if kind == "tls":
            gens[(blk, sock)] = gens.get((blk, sock), 0) + 1
            streams[(blk, sock, gens[(blk, sock)])] = Stream(t, sock)
        else:
            key = (blk, sock, gens.get((blk, sock), 0))
            if key not in streams:
                streams[key] = Stream(t, sock)
            streams[key].feed(*payload)

    # ---- pass 3: decode every framed request ----
    out = sys.stdout
    for key, st in streams.items():
        blk, sock, gen = key
        for raw in st.requests:
            sep = raw.find(b"\r\n\r\n")
            head = raw[:sep].decode("utf-8", "replace")
            body = raw[sep + 4 :]
            lines = head.split("\r\n")
            parts = lines[0].split(" ")
            headers = {}
            for hl in lines[1:]:
                if ":" in hl:
                    k, v = hl.split(":", 1)
                    headers[k.strip()] = v.strip()
            try:
                jbody = json.loads(body) if body else None
            except Exception:
                jbody = {"_raw": body[:300].decode("utf-8", "replace")}
            rec = {
                "block": blk,
                "ts": st.ts0,
                "sock": sock,
                "gen": gen,
                "method": parts[0] if parts else "?",
                "path": parts[1] if len(parts) > 1 else "?",
                "headers": headers,
                "body": jbody,
                "blen": len(body),
            }
            out.write(json.dumps(rec) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
