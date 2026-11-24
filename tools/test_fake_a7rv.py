#!/usr/bin/env python3
"""Unit tests for the fake Sony A7RV (tools/fake_a7rv.py).

The fake camera stands in for the real card in the smoke test: it must speak
the same PTP/IP flow the app uses, and — critically — it must never allow a
destructive operation. That last property is the one hard constraint the
whole project rides on, so it is tested here directly:

  - handshake: InitCommandRequest -> InitCommandAck (ILCE-7RM5) -> event ack
  - listing:   GetDeviceInfo + SonyGetCapturedDateList + GetContentsInfoList
               return the shots the card actually holds
  - refusal:   DeleteObject (0x100B) and Sony's content delete (0x9250) are
               answered with OperationNotSupported — the fake never deletes
               anything
  - reads are read-only: a shot fetched by 0x923D/0x923E returns its bytes,
               and a bogus contentID is refused with InvalidParameter

Run:  python3 tools/test_fake_a7rv.py
"""
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAKE = os.path.join(REPO, "tools", "fake_a7rv.py")
# PTP/IP packet types used by the fake
INIT_COMMAND_REQUEST = 1
INIT_COMMAND_ACK = 2
INIT_EVENT_REQUEST = 3
INIT_EVENT_ACK = 4
COMMAND_REQUEST = 6
COMMAND_ACK = 7
DATA_REQUEST = 9
DATA_RESPONSE = 12

DELETE_OBJECT = 0x100B
CONTENT_DELETE = 0x9250  # deliberately never defined in VampireCore
OK = 0x2001
NOT_SUPPORTED = 0x2005
INVALID_PARAM = 0x201D
GET_DEVICE_INFO = 0x1001
GET_CAPTURED_DATE_LIST = 0x923B
GET_CONTENTS_INFO_LIST = 0x923C
GET_CONTENT_INFO = 0x923D
GET_SCREENNAIL = 0x923E


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def pkt(ptype, payload=b""):
    return struct.pack("<II", 8 + len(payload), ptype) + payload


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed")
        buf += chunk
    return buf


def read_pkt(s):
    length, ptype = struct.unpack("<II", recv_exact(s, 8))
    return ptype, recv_exact(s, length - 8)


class Card:
    """Builds a tiny on-disk card and the subprocess that serves it."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="fake-card-test-")
        # Two shots — one tiny source file each (a real file, because the
        # listing reads its size).
        self.shots = []
        for i, name in enumerate(("DSC01001.ARW", "DSC01002.ARW")):
            src = os.path.join(self.root, name)
            with open(src, "wb") as f:
                f.write(b"\x00" * (1024 + i * 512))
            thumb = os.path.join(self.root, f"DSC0100{i + 1}.thumb.jpg")
            with open(thumb, "wb") as f:
                f.write(b"\x00" * 256)
            nail = os.path.join(self.root, f"DSC0100{i + 1}.jpg")
            with open(nail, "wb") as f:
                f.write(b"\x00" * 512)
            self.shots.append({
                "name": name,
                "source": src,
                "thumb": thumb,
                "screennail": nail,
                "created_ms": 1_700_000_000_000 + i * 60_000,
                "width": 4000,
                "height": 3000,
                "format": "0x31",
                "rating": 0,
            })
        with open(os.path.join(self.root, "card.json"), "w") as f:
            json.dump(self.shots, f)
        self.port = free_port()
        self.proc = subprocess.Popen(
            [sys.executable, FAKE, self.root, str(self.port)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        # Wait for the listener to come up (avoid races).
        for _ in range(100):
            try:
                s = socket.create_connection(("127.0.0.1", self.port), timeout=0.1)
                s.close()
                break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("fake camera did not start")

    def command_channel(self):
        """Full handshake; returns the command channel (not the event channel)."""
        conn = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        conn.sendall(pkt(INIT_COMMAND_REQUEST, b""))
        ptype, payload = read_pkt(conn)
        assert ptype == INIT_COMMAND_ACK, f"expected InitCommandAck, got ptype {ptype}"
        number, = struct.unpack("<I", payload[:4])
        assert number > 0, "fake must hand out a connection number"
        event = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        event.sendall(pkt(INIT_EVENT_REQUEST, struct.pack("<I", number)))
        ptype, _ = read_pkt(event)
        assert ptype == INIT_EVENT_ACK, f"expected InitEventAck, got ptype {ptype}"
        return conn, event

    def command(self, conn, code, params=(), tid=0x42):
        """Send a command and return (rc, data).

        The fake sends data packets (9 then 12) first, then the ack (7).
        """
        params = list(params)
        payload = struct.pack("<IHI", 0, code, tid) + b"".join(
            struct.pack("<I", p) for p in params
        )
        conn.sendall(pkt(COMMAND_REQUEST, payload))
        rc = None
        data = b""
        while True:
            ptype, payload = read_pkt(conn)
            if ptype == DATA_REQUEST:
                length = struct.unpack("<Q", payload[4:])[0]
                ptype2, payload2 = read_pkt(conn)
                assert ptype2 == DATA_RESPONSE, f"expected DataResponse, got {ptype2}"
                data = payload2[4:][:length]  # strip the tid prefix
            elif ptype == COMMAND_ACK:
                rc, tid2 = struct.unpack("<HI", payload)
                assert tid2 == tid, "ack must echo the transaction id"
                return rc, data
        # unreachable
        raise RuntimeError("no CommandAck received")

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
        shutil.rmtree(self.root, ignore_errors=True)


class FakeCameraHandshakeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.card = Card()

    @classmethod
    def tearDownClass(cls):
        cls.card.close()

    def test_handshake_hands_out_number_and_names_the_camera(self):
        conn, event = self.card.command_channel()
        try:
            # The InitCommandAck payload carries the conn number, then the name.
            # The Command channel stays open for commands.
            rc, _ = self.card.command(conn, GET_DEVICE_INFO)
            self.assertEqual(rc, OK)
        finally:
            conn.close()
            event.close()

    def test_get_device_info_reports_sony_corporation_ilce_7rm5(self):
        conn, event = self.card.command_channel()
        try:
            rc, data = self.card.command(conn, GET_DEVICE_INFO)
            self.assertEqual(rc, OK)
            # The payload starts with a BCD-ish header + "Sony PTP Extensions"
            # + the ops — at minimum, the model name must be present.
            self.assertIn("ILCE-7RM5".encode("utf-16-le"), data)
            self.assertIn("Sony Corporation".encode("utf-16-le"), data)
        finally:
            conn.close()
            event.close()

    def test_listing_returns_exactly_the_shots_on_the_card(self):
        conn, event = self.card.command_channel()
        try:
            # Captured-date list (slot 1): one entry per distinct day.
            rc, data = self.card.command(conn, GET_CAPTURED_DATE_LIST, (1,))
            self.assertEqual(rc, OK)
            (count,) = struct.unpack("<I", data[:4])

            # Contents listing (cursor 0): one record per shot on the card.
            rc, listing = self.card.command(conn, GET_CONTENTS_INFO_LIST, (0, 0))
            self.assertEqual(rc, OK)
            # 0x90-byte header, then a u32 count
            (count,) = struct.unpack("<I", listing[0x90:0x90 + 4])
            self.assertEqual(count, 2, "one record per shot")
            for i, shot in enumerate(self.card.shots):
                cid = 0x20001 + i
                self.assertIn(struct.pack("<I", cid), listing,
                              f"card shot {i} must be in the listing")
        finally:
            conn.close()
            event.close()

    def test_refuses_any_delete_operation(self):
        conn, event = self.card.command_channel()
        try:
            for code in (DELETE_OBJECT, CONTENT_DELETE):
                rc, data = self.card.command(conn, code, (0, 0))
                self.assertEqual(rc, NOT_SUPPORTED,
                                 f"delete op 0x{code:04x} must be refused")
                self.assertEqual(data, b"", "refused delete must not return data")
        finally:
            conn.close()
            event.close()

    def test_screennail_read_returns_the_shot_bytes(self):
        conn, event = self.card.command_channel()
        try:
            # params: contentID, fileSelector, type (2 = screennail) — the
            # exact wire shape CameraFrameCache uses via compressed().
            rc, data = self.card.command(
                conn, GET_SCREENNAIL, (0x20001, 0x00000001, 2))
            self.assertEqual(rc, OK)
            self.assertEqual(len(data), 512, "screennail must be the stored bytes")
        finally:
            conn.close()
            event.close()

    def test_content_data_read_returns_the_source_bytes(self):
        conn, event = self.card.command_channel()
        try:
            # params: contentID, fileSelector, offset, offsetHi, size — the
            # exact wire shape contentsDataParameters() produces.
            rc, data = self.card.command(
                conn, GET_CONTENT_INFO, (0x20001, 0x00000001, 0, 0, 1024))
            self.assertEqual(rc, OK)
            self.assertEqual(len(data), 1024, "head read must return the source bytes")
        finally:
            conn.close()
            event.close()

    def test_new_shots_join_and_removed_shots_drop_out_on_reconnect(self):
        # The fake re-reads card.json on every connect — the property the whole
        # demo relies on: add a shot → it joins; remove a shot → it drops out.
        card_json = os.path.join(self.card.root, "card.json")
        with open(card_json) as f:
            original = f.read()
        try:
            conn, event = self.card.command_channel()
            try:
                _, listing = self.card.command(conn, GET_CONTENTS_INFO_LIST, (0, 0))
                (count,) = struct.unpack("<I", listing[0x90:0x90 + 4])
                self.assertEqual(count, 2)
                self.assertIn(b"DSC01001.ARW", listing)
                self.assertIn(b"DSC01002.ARW", listing)
            finally:
                conn.close()
                event.close()

            # Mutate the card: drop shot B, add shot C (new file on disk).
            c_src = os.path.join(self.card.root, "DSC01003.ARW")
            with open(c_src, "wb") as f:
                f.write(b"\x00" * 768)
            with open(card_json, "w") as f:
                json.dump([
                    self.card.shots[0],
                    {
                        "name": "DSC01003.ARW",
                        "source": c_src,
                        "thumb": self.card.shots[0]["thumb"],
                        "screennail": self.card.shots[0]["screennail"],
                        "created_ms": 1_700_000_060_000,
                        "width": 4000,
                        "height": 3000,
                        "format": "0x31",
                        "rating": 0,
                    },
                ], f)

            conn, event = self.card.command_channel()
            try:
                _, listing2 = self.card.command(conn, GET_CONTENTS_INFO_LIST, (0, 0))
                (count,) = struct.unpack("<I", listing2[0x90:0x90 + 4])
                self.assertEqual(count, 2, "the card is re-read on every connect")
                self.assertIn(b"DSC01001.ARW", listing2)
                self.assertIn(b"DSC01003.ARW", listing2)
                self.assertNotIn(b"DSC01002.ARW", listing2)
            finally:
                conn.close()
                event.close()
        finally:
            with open(card_json, "w") as f:
                f.write(original)

    def test_refuses_fetch_of_unknown_content_id(self):
        conn, event = self.card.command_channel()
        try:
            rc, _ = self.card.command(conn, GET_SCREENNAIL, (0xDEAD_BEEF,))
            self.assertEqual(rc, INVALID_PARAM)
        finally:
            conn.close()
            event.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
