#!/usr/bin/env python3
"""A fake Sony A7RV over PTP/IP, for developing and demoing camera sessions
without a camera (simulator screenshots, reconnect/prune testing).

    python3 tools/make_fake_card.py /tmp/fakecard     # build a card from fixtures
    python3 tools/fake_a7rv.py /tmp/fakecard          # serve it on :15740

Then point the app at this Mac's IP (Find & Connect, or Enter IP manually).
The card is `<dir>/card.json`, re-read on every connect, so you can add or
remove shots between connects to exercise "new shots join" / "deleted shots
drop out".

Speaks only what the app uses, with the byte layouts the real A7RV returned
(see VampireCore/Sources/PTP/SonyContents.swift): handshake, GetDeviceInfo,
OpenSession, Sony SDIO connect, remote transfer 0x923B-0x923E. It refuses
anything else — including every delete — with OperationNotSupported.
"""
import json, os, socket, struct, sys, threading

PORT = 15740
OK, NOT_SUPPORTED, INVALID_PARAM = 0x2001, 0x2005, 0x201D

def pkt(ptype, payload=b""):
    return struct.pack("<II", 8 + len(payload), ptype) + payload

def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf

def read_pkt(s):
    length, ptype = struct.unpack("<II", recv_exact(s, 8))
    return ptype, recv_exact(s, length - 8)

def ptp_string(text):
    if not text:
        return b"\0"
    units = text.encode("utf-16-le") + b"\0\0"
    return bytes([len(units) // 2]) + units

def u16_array(values):
    return struct.pack("<I", len(values)) + b"".join(struct.pack("<H", v) for v in values)

OPS = [0x1001, 0x1002, 0x1003, 0x9201, 0x9202, 0x923B, 0x923C, 0x923D, 0x923E]

def device_info():
    return (struct.pack("<HIH", 100, 0x11, 100) + ptp_string("Sony PTP Extensions") + struct.pack("<H", 0)
            + u16_array(OPS) + u16_array([]) + u16_array([]) + u16_array([])
            + u16_array([0x3801, 0xB101]) + ptp_string("Sony Corporation")
            + ptp_string("ILCE-7RM5") + ptp_string("3.00") + ptp_string("FAKE0001"))

class Card:
    def __init__(self, root):
        self.root = root
        with open(os.path.join(root, "card.json")) as f:
            self.shots = json.load(f)
        for i, shot in enumerate(self.shots):
            shot["cid"] = 0x20001 + i

    def path(self, name):
        return os.path.join(self.root, name) if not os.path.isabs(name) else name

    def by_cid(self, cid):
        return next((s for s in self.shots if s["cid"] == cid), None)

    def contents_list(self, cursor):
        page = [s for s in self.shots if s["created_ms"] > cursor][:100]
        out = struct.pack("<IQ", 100, 0) + b"\0" * (0x90 - 12) + struct.pack("<I", len(page))
        for s in page:
            source = self.path(s["source"])
            path = f"C:/DCIM/100MSDCF/{s['name']}".encode() + b"\0"
            out += struct.pack("<7I", 1, s["cid"], 100, int(s["name"][3:8]), 0, 0, 1)
            out += struct.pack("<4Q", s["created_ms"], s["created_ms"], s["created_ms"], s["created_ms"])
            out += struct.pack("<iII", s.get("rating", 0), 0, 1)
            out += struct.pack("<I", 0)  # shot marks
            out += struct.pack("<I", 1)  # one file
            out += struct.pack("<HH", 1, 0) + struct.pack("<I", len(path)) + path
            out += struct.pack("<IQ", int(s["format"], 16), os.path.getsize(source))
            out += b"\0" * 32  # UMID
            out += struct.pack("<III", 1, s["width"], s["height"])
            out += struct.pack("<II", 0, 0)  # no video/audio params
        return out

def serve(conn, card, first_tid_conn):
    while True:
        try:
            ptype, payload = read_pkt(conn)
        except EOFError:
            return
        if ptype != 6:
            continue
        _, code, tid = struct.unpack_from("<IHI", payload)
        params = list(struct.unpack_from(f"<{(len(payload) - 10) // 4}I", payload, 10))
        rc, data = OK, None
        if code == 0x1001:
            data = device_info()
        elif code in (0x1002, 0x1003):
            pass
        elif code == 0x9201:
            data = b"\0" * 8
        elif code == 0x9202:
            data = struct.pack("<H", 0x12C) + u16_array([]) + u16_array([])
        elif code == 0x923B:  # captured-date list per slot
            if params[0] == 1:
                days = sorted({s["created_ms"] // 86_400_000 for s in card.shots})
                data = struct.pack("<I", len(days)) + b"".join(struct.pack("<Q", d * 86_400_000) for d in days)
            else:
                rc = INVALID_PARAM
        elif code == 0x923C:
            data = card.contents_list(params[0] | params[1] << 32)
        elif code in (0x923D, 0x923E):
            shot = card.by_cid(params[0])
            if shot is None:
                rc = INVALID_PARAM
            elif code == 0x923E:
                key = "thumb" if params[2] == 1 else "screennail"
                data = open(card.path(shot[key]), "rb").read()
            else:
                offset = params[2] | params[3] << 32
                size = params[4] & 0x7FFF_FFFF
                with open(card.path(shot["source"]), "rb") as f:
                    f.seek(offset)
                    data = f.read(size)
        else:
            rc = NOT_SUPPORTED  # never anything destructive
        if data is not None:
            conn.sendall(pkt(9, struct.pack("<IQ", tid, len(data))) + pkt(12, struct.pack("<I", tid) + data))
        conn.sendall(pkt(7, struct.pack("<HI", rc, tid)))

def main():
    root = sys.argv[1]
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT))
    srv.listen(8)
    print(f"fake ILCE-7RM5 serving {root} on :{PORT}", flush=True)
    pending = {}
    lock = threading.Lock()

    def handshake(conn, addr):
        # One thread per connection: a finder's port probe connects and
        # never speaks; it must not block real clients.
        conn.settimeout(10)
        try:
            ptype, payload = read_pkt(conn)
        except (EOFError, OSError):
            conn.close()
            return
        conn.settimeout(None)
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        if ptype == 1:  # InitCommandRequest
            card = Card(root)
            with lock:
                number = len(pending) + 1 + int.from_bytes(os.urandom(2), "little")
                pending[number] = (conn, card)
            reply = struct.pack("<I", number) + b"\0" * 16 + "ILCE-7RM5\0".encode("utf-16-le") + struct.pack("<I", 0x10000)
            conn.sendall(pkt(2, reply))
            print(f"{addr[0]} connected — card has {len(card.shots)} shots", flush=True)
        elif ptype == 3:  # InitEventRequest: start serving the command channel
            number = struct.unpack_from("<I", payload)[0]
            with lock:
                command, card = pending.pop(number)
            conn.sendall(pkt(4))
            threading.Thread(target=serve, args=(command, card, number), daemon=True).start()
            try:  # keep the event channel open (drained) for the session's life
                while conn.recv(64):
                    pass
            except OSError:
                pass

    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handshake, args=(conn, addr), daemon=True).start()

if __name__ == "__main__":
    main()
