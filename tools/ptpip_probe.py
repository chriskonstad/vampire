#!/usr/bin/env python3
"""PTP/IP probe for the A7RV — run from the Mac on the same network as the
camera to see exactly what the camera exposes, before touching the app.

    python3 tools/ptpip_probe.py <camera-ip> [--pull-head]

Read-only: never sends DeleteObject (0x100B), Sony delete (0x9250) or any
write op. Sony wire details per alpha2go's docs/protocol.md (a6700-verified). Mirrors the app's
VampireCore/Sources/PTP codec so findings transfer directly.
"""
import socket, struct, sys, uuid, time

PORT = 15740
GUID_FILE = "/tmp/vampire-ptp-guid"

def guid():
    try:
        return bytes.fromhex(open(GUID_FILE).read().strip())
    except Exception:
        g = uuid.uuid4().bytes
        open(GUID_FILE, "w").write(g.hex())
        return g

def pkt(ptype, payload=b""):
    return struct.pack("<II", 8 + len(payload), ptype) + payload

def utf16z(s):
    return s.encode("utf-16-le") + b"\0\0"

def read_pkt(sock):
    hdr = recv_exact(sock, 8)
    length, ptype = struct.unpack("<II", hdr)
    return ptype, recv_exact(sock, length - 8)

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError(f"socket closed after {len(buf)}/{n} bytes")
        buf += chunk
    return buf

def hexdump(b, n=64):
    return b[:n].hex(" ") + (" …" if len(b) > n else "")

def ptp_string(b, off):
    n = b[off]; off += 1
    if n == 0:
        return "", off
    s = b[off:off + 2 * n].decode("utf-16-le").rstrip("\0")
    return s, off + 2 * n

def u16_array(b, off):
    (n,) = struct.unpack_from("<I", b, off); off += 4
    return list(struct.unpack_from(f"<{n}H", b, off)), off + 2 * n

def u32_array(b, off=0):
    (n,) = struct.unpack_from("<I", b, off); off += 4
    return list(struct.unpack_from(f"<{n}I", b, off)), off + 4 * n

class Cam:
    def __init__(self, ip):
        self.tid = 0
        print(f"→ TCP connect {ip}:{PORT}")
        self.cmd = socket.create_connection((ip, PORT), timeout=10)
        self.cmd.sendall(pkt(1, guid() + utf16z("Vampire") + struct.pack("<I", 0x00010000)))
        t, p = read_pkt(self.cmd)
        print(f"← type {t}: {hexdump(p)}")
        if t != 2:
            raise SystemExit(f"InitCommand failed (type {t}, reason {p[:4].hex()})")
        self.conn_no = struct.unpack_from("<I", p, 0)[0]
        name = p[20:].decode("utf-16-le", "replace").split("\0")[0]
        print(f"  InitCommandAck conn#{self.conn_no} name={name!r}")
        print(f"→ TCP connect event channel")
        self.evt = socket.create_connection((ip, PORT), timeout=10)
        self.evt.sendall(pkt(3, struct.pack("<I", self.conn_no)))
        t, p = read_pkt(self.evt)
        print(f"← event type {t}: {hexdump(p)}")
        if t != 4:
            raise SystemExit(f"InitEvent failed (type {t})")

    def op(self, code, params=(), quiet=False):
        self.tid += 1
        payload = struct.pack("<IHI", 1, code, self.tid) + b"".join(struct.pack("<I", x) for x in params)
        self.cmd.sendall(pkt(6, payload))
        data = b""; total = None
        while True:
            t, p = read_pkt(self.cmd)
            if t == 9:   # StartData
                total = struct.unpack_from("<Q", p, 4)[0]
            elif t in (10, 12):
                data += p[4:]
            elif t == 7:
                rc = struct.unpack_from("<H", p, 0)[0]
                if not quiet or rc != 0x2001:
                    print(f"  op 0x{code:04X} {list(map(hex, params))} → 0x{rc:04X}, {len(data)} bytes"
                          + (f" (announced {total})" if total is not None else ""))
                return rc, data
            else:
                print(f"  (ignored packet type {t})")

def device_info(d):
    off = 0
    std_ver, vendor_id, vendor_ver = struct.unpack_from("<HIH", d, off); off += 8
    ext, off = ptp_string(d, off)
    off += 2  # functional mode
    ops, off = u16_array(d, off)
    events, off = u16_array(d, off)
    props, off = u16_array(d, off)
    cap_fmts, off = u16_array(d, off)
    img_fmts, off = u16_array(d, off)
    mfr, off = ptp_string(d, off)
    model, off = ptp_string(d, off)
    ver, off = ptp_string(d, off)
    print(f"  {mfr} {model} fw {ver} vendor 0x{vendor_id:X} ext={ext!r}")
    print(f"  ops ({len(ops)}): {' '.join(f'{o:04X}' for o in ops)}")
    print(f"  image formats: {' '.join(f'{o:04X}' for o in img_fmts)}")
    return ops

def object_info(d):
    storage, fmt, prot, size = struct.unpack_from("<IHHI", d, 0)
    _, thumb_size = struct.unpack_from("<HI", d, 12)
    w, h = struct.unpack_from("<II", d, 26)
    name, _ = ptp_string(d, 52)
    return dict(fmt=f"{fmt:04X}", size=size, thumb=thumb_size, w=w, h=h, name=name)

def contents_list(d):
    """Parse a 0x923C reply (alpha2go docs/protocol.md layout)."""
    (count,) = struct.unpack_from("<I", d, 0x90)
    off = 0x94
    out = []
    for _ in range(count):
        ctype, cid, dirno, fileno, gtype, gid, rep = struct.unpack_from("<7I", d, off); off += 28
        created_utc, modified_utc, created_local, modified_local = struct.unpack_from("<4Q", d, off); off += 32
        rating, protected, dummy = struct.unpack_from("<iII", d, off); off += 12
        (marks,) = struct.unpack_from("<I", d, off); off += 4 + marks
        (nfiles,) = struct.unpack_from("<I", d, off); off += 4
        files = []
        for _ in range(nfiles):
            (fid,) = struct.unpack_from("<H", d, off); off += 4
            (plen,) = struct.unpack_from("<I", d, off); off += 4
            path = d[off:off + plen].split(b"\0")[0].decode(errors="replace"); off += plen
            fmt, size = struct.unpack_from("<IQ", d, off); off += 12
            off += 32  # UMID
            (has_img,) = struct.unpack_from("<I", d, off); off += 4
            w = h = 0
            if has_img:
                w, h = struct.unpack_from("<II", d, off); off += 8
            (has_vid,) = struct.unpack_from("<I", d, off); off += 4
            if has_vid: off += 19 * 4
            (has_aud,) = struct.unpack_from("<I", d, off); off += 4
            if has_aud: off += 4 * 4
            files.append(dict(fid=fid, path=path, fmt=f"{fmt:04X}", size=size, w=w, h=h))
        out.append(dict(type=ctype, cid=cid, created=created_utc, rating=rating,
                        protected=protected, files=files))
    return out

def remote_transfer(cam):
    """Card access in remote mode (camera UI stays usable)."""
    for slot in (1, 2):
        rc, d = cam.op(0x923B, [slot])
        if rc != 0x2001:
            print(f"  slot {slot}: date list → 0x{rc:04X} (empty/absent)")
            continue
        (n,) = struct.unpack_from("<I", d, 0)
        print(f"  slot {slot}: {n} capture dates")
        if n == 0:
            continue
        t0 = time.time()
        rc, d = cam.op(0x923C, [0, 0, 100, slot, 0])
        if rc != 0x2001:
            continue
        items = contents_list(d)
        print(f"  slot {slot}: first page {len(items)} contents ({time.time()-t0:.2f}s)")
        for it in items[:5]:
            print(f"    {it}")
        raws = [(it, f) for it in items for f in it["files"] if f["fmt"] == "B101"]
        if not raws:
            continue
        it, f = raws[-1]
        sel = (slot << 24) | f["fid"]
        for typ, label in ((1, "thumbnail"), (2, "screennail")):
            t0 = time.time()
            rc, img = cam.op(0x923E, [it["cid"], sel, typ])
            print(f"  {label}: {len(img)} bytes, magic {img[:12].hex()} ({time.time()-t0:.2f}s)")
            open(f"/tmp/vampire-{label}.bin", "wb").write(img)
        head = 256 * 1024
        t0 = time.time()
        rc, d = cam.op(0x923D, [it["cid"], sel, 0, 0, head | (1 << 31 if head >= f["size"] else 0)])
        print(f"  head {f['path']}: {len(d)} bytes, starts {d[:8].hex()} ({time.time()-t0:.2f}s)")
        open("/tmp/vampire-head.bin", "wb").write(d)
        return

def main():
    ip = sys.argv[1]
    cam = Cam(ip)
    rc, d = cam.op(0x1001)
    ops = device_info(d) if rc == 0x2001 else []
    rc, _ = cam.op(0x1002, [1])
    if rc != 0x2001:
        raise SystemExit("OpenSession failed")
    for phase in (1, 2):
        cam.op(0x9201, [phase, 0, 0])
    cam.op(0x9202, [0x12C, 1])
    cam.op(0x9201, [3, 0, 0])
    if "--remote-transfer" in sys.argv:
        remote_transfer(cam)
        cam.op(0x1003)
        return
    rc, d = cam.op(0x1004)
    storages = u32_array(d)[0] if rc == 0x2001 and d else []
    print(f"  storages: {list(map(hex, storages))}")
    first_raw = None
    for s in storages:
        rc, d = cam.op(0x1005, [s])
        rc, d = cam.op(0x1007, [s, 0, 0])
        if rc != 0x2001:
            continue
        handles = u32_array(d)[0]
        print(f"  storage {s:#x}: {len(handles)} objects")
        images = 0
        for h in handles:
            rc, d = cam.op(0x1008, [h], quiet=True)
            if rc != 0x2001:
                continue
            info = object_info(d)
            if info["fmt"] == "3001":
                continue
            images += 1
            if images <= 8:
                print(f"    {h:#010x} {info}")
            if first_raw is None and info["fmt"] == "B101":
                first_raw = h
        print(f"  {images} non-folder objects")
    if first_raw is not None:
        t0 = time.time()
        rc, d = cam.op(0x100A, [first_raw])
        print(f"  GetThumb: {len(d)} bytes, starts {d[:4].hex()} ({time.time()-t0:.2f}s)")
        if "--pull-head" in sys.argv:
            t0 = time.time()
            rc, d = cam.op(0x101B, [first_raw, 0, 256 * 1024])
            dt = time.time() - t0
            print(f"  GetPartialObject head: {len(d)} bytes in {dt:.2f}s, starts {d[:8].hex()}")
            open("/tmp/vampire-head.bin", "wb").write(d)
    cam.op(0x1003)

if __name__ == "__main__":
    main()
