#!/usr/bin/env python3
"""Python 3 (standard library only, Linux) fallback for the rcp-update Rust binary.

Same subcommands, same stdout contract, same frames as `rcp-update`:
  frame {reset-bootloader|version}     print the HDLC frame as hex
  list                                 USB ttys with VID:PID (sysfs)
  touch --port P [--baud 1200] [--hold-ms 150]
  find-tty --vid-pid VID:PID [--timeout 10] [--exclude PATH]
  reset-bootloader --port P --baud B [--flow]
  version --port P --baud B [--flow] [--timeout 5]

Exit codes: 0 ok, 1 failed, 2 usage. Framing re-derived from OpenThread src/lib/hdlc/hdlc.cpp
(FCS-16 init 0xFFFF, reflected poly 0x8408, complemented, low byte first, escape 0x11 0x13 0x7D
0x7E 0xF8) and src/lib/spinel/spinel.h. NOT verified on hardware.
"""
import argparse
import os
import sys
import time

FLAG, ESC = 0x7E, 0x7D
GOOD_FCS = 0xF0B8


def update_fcs(fcs, byte):
    c = fcs ^ byte
    for _ in range(8):
        c = (c >> 1) ^ 0x8408 if c & 1 else c >> 1
    return c


def fcs16(data):
    f = 0xFFFF
    for b in data:
        f = update_fcs(f, b)
    return f ^ 0xFFFF


def _esc(out, b):
    if b in (0x11, 0x13, 0x7D, 0x7E, 0xF8):
        out += bytes((ESC, b ^ 0x20))
    else:
        out.append(b)


def hdlc_encode(payload):
    f = fcs16(payload)
    out = bytearray([FLAG])
    for b in payload:
        _esc(out, b)
    _esc(out, f & 0xFF)
    _esc(out, f >> 8)
    out.append(FLAG)
    return bytes(out)


class Decoder:
    def __init__(self):
        self.synced = False
        self.escaped = False
        self.buf = bytearray()
        self.fcs = 0xFFFF

    def _push(self, b):
        if len(self.buf) >= 2048:
            self.synced = False
            self.buf.clear()
            return
        self.fcs = update_fcs(self.fcs, b)
        self.buf.append(b)

    def feed(self, b):
        if not self.synced:
            if b == FLAG:
                self.synced, self.escaped, self.fcs = True, False, 0xFFFF
                self.buf.clear()
            return None
        if self.escaped:
            self.escaped = False
            self._push(b ^ 0x20)
            return None
        if b == ESC:
            self.escaped = True
            return None
        if b == FLAG:
            out = None
            if len(self.buf) >= 2 and self.fcs == GOOD_FCS:
                out = bytes(self.buf[:-2])
            self.buf.clear()
            self.fcs = 0xFFFF
            return out
        self._push(b)
        return None


def reset_frame():
    return hdlc_encode(bytes([0x81, 0x01, 0x03]))  # hdr TID1, CMD_RESET, SPINEL_RESET_BOOTLOADER


def version_frame():
    return hdlc_encode(bytes([0x81, 0x02, 0x02]))  # hdr TID1, CMD_PROP_VALUE_GET, PROP_NCP_VERSION


def parse_version(frame, tid=1):
    # header, CMD_PROP_VALUE_IS (6), PROP_NCP_VERSION (2), NUL terminated string
    if len(frame) < 3 or not frame[0] & 0x80 or (frame[0] & 0x0F) != tid:
        return None
    if frame[1] != 6 or frame[2] != 2:
        return None
    return frame[3:].split(b"\0", 1)[0].decode("utf-8", "replace")


def hexs(b):
    return " ".join("%02X" % x for x in b)


def die(msg):
    sys.stderr.write("rcp_spinel.py: %s\n" % msg)
    sys.exit(1)


def open_tty(port, baud, flow, timeout_s=0.1):
    import termios

    const = getattr(termios, "B%d" % baud, None)
    if const is None:
        die("unsupported baud %d" % baud)
    try:
        fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except OSError as e:
        die("cannot open %s: %s (busy? stop otbr-agent; permission? dialout group)" % (port, e))
    try:
        import fcntl

        fcntl.ioctl(fd, termios.TIOCEXCL)
    except Exception:
        pass
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, _, _, cc = attrs
    iflag = 0
    oflag = 0
    lflag = 0
    cflag &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB | getattr(termios, "CRTSCTS", 0))
    cflag |= termios.CS8 | termios.CLOCAL | termios.CREAD | termios.HUPCL
    if flow:
        cflag |= termios.CRTSCTS
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, const, const, cc])
    return fd


def set_dtr(fd, on):
    import fcntl
    import struct
    import termios

    req = termios.TIOCMBIS if on else termios.TIOCMBIC
    fcntl.ioctl(fd, req, struct.pack("I", termios.TIOCM_DTR))


def list_usb_ttys():
    out = []
    base = "/sys/class/tty"
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return out
    for name in names:
        if not (name.startswith("ttyACM") or name.startswith("ttyUSB")):
            continue
        try:
            d = os.path.realpath(os.path.join(base, name, "device"))
        except OSError:
            continue
        for _ in range(6):
            v, p = os.path.join(d, "idVendor"), os.path.join(d, "idProduct")
            if os.path.exists(v) and os.path.exists(p):
                try:
                    out.append(("/dev/" + name, int(open(v).read().strip(), 16), int(open(p).read().strip(), 16)))
                except (OSError, ValueError):
                    pass
                break
            d = os.path.dirname(d)
    return out


def cmd_touch(a):
    fd = open_tty(a.port, a.baud, False)
    try:
        if a.baud != 1200:
            sys.stderr.write("warning: touch baud is %d, firmware reacts only to 1200\n" % a.baud)
        try:
            set_dtr(fd, True)
        except OSError:
            pass
        time.sleep(max(a.hold_ms, 100) / 1000.0)
        try:
            set_dtr(fd, False)
        except OSError:
            pass
        time.sleep(0.15)
    finally:
        os.close(fd)
    sys.stderr.write("touch done on %s (1200 baud, held %d ms)\n" % (a.port, a.hold_ms))


def cmd_find(a):
    try:
        vid, pid = [int(x, 16) for x in a.vid_pid.split(":")]
    except ValueError:
        sys.stderr.write("bad --vid-pid\n")
        sys.exit(2)
    end = time.time() + a.timeout
    while True:
        for path, v, p in list_usb_ttys():
            if v == vid and p == pid and path != a.exclude:
                t = time.time() + 3
                while time.time() < t:
                    try:
                        os.close(os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK))
                        break
                    except OSError:
                        time.sleep(0.1)
                time.sleep(0.3)
                print(path)
                return
        if time.time() >= end:
            die("no USB tty with %04x:%04x within %.1fs" % (vid, pid, a.timeout))
        time.sleep(0.1)


def cmd_reset(a):
    if a.baud == 1200:
        die("refusing baud 1200 for Spinel")
    import termios

    fd = open_tty(a.port, a.baud, a.flow)
    try:
        termios.tcflush(fd, termios.TCIOFLUSH)
        fr = reset_frame()
        sys.stderr.write("sending %s at %d 8N1%s\n" % (hexs(fr), a.baud, " +RTS/CTS" if a.flow else ""))
        view = memoryview(fr)
        end = time.time() + 2
        while view and time.time() < end:
            try:
                n = os.write(fd, view)
                view = view[n:]
            except BlockingIOError:
                time.sleep(0.01)
        termios.tcdrain(fd)
        time.sleep(0.1)
    finally:
        os.close(fd)


def cmd_version(a):
    if a.baud == 1200:
        die("refusing baud 1200 for Spinel")
    import select
    import termios

    fd = open_tty(a.port, a.baud, a.flow)
    try:
        termios.tcflush(fd, termios.TCIFLUSH)
        dec = Decoder()
        deadline = time.time() + a.timeout
        while time.time() < deadline:
            os.write(fd, version_frame())
            termios.tcdrain(fd)
            attempt_end = min(time.time() + 1.0, deadline)
            while time.time() < attempt_end:
                r, _, _ = select.select([fd], [], [], 0.1)
                if not r:
                    continue
                for b in os.read(fd, 256):
                    fr = dec.feed(b)
                    if fr is not None:
                        v = parse_version(fr)
                        if v is not None:
                            print(v)
                            return
        die("no Spinel version reply from %s at %d within %.1fs" % (a.port, a.baud, a.timeout))
    finally:
        os.close(fd)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("frame")
    s.add_argument("kind", choices=["reset-bootloader", "version"])
    sub.add_parser("list")
    s = sub.add_parser("touch")
    s.add_argument("--port", required=True)
    s.add_argument("--baud", type=int, default=1200)
    s.add_argument("--hold-ms", type=int, default=150)
    s = sub.add_parser("find-tty")
    s.add_argument("--vid-pid", required=True)
    s.add_argument("--timeout", type=float, default=10.0)
    s.add_argument("--exclude")
    for n in ("reset-bootloader", "version"):
        s = sub.add_parser(n)
        s.add_argument("--port", required=True)
        s.add_argument("--baud", type=int, required=True)
        s.add_argument("--flow", action="store_true")
        if n == "version":
            s.add_argument("--timeout", type=float, default=5.0)
    a = ap.parse_args()
    if a.cmd == "frame":
        print(hexs(reset_frame() if a.kind == "reset-bootloader" else version_frame()))
    elif a.cmd == "list":
        for p, v, i in list_usb_ttys():
            print("%s %04x:%04x" % (p, v, i))
    elif a.cmd == "touch":
        cmd_touch(a)
    elif a.cmd == "find-tty":
        cmd_find(a)
    elif a.cmd == "reset-bootloader":
        cmd_reset(a)
    elif a.cmd == "version":
        cmd_version(a)


if __name__ == "__main__":
    main()
