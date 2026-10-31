//! HDLC-lite framing as used by Spinel over a UART or USB CDC ACM link.
//!
//! Re-derived from OpenThread `src/lib/hdlc/hdlc.cpp` (main branch, fetched 2026-10-21):
//! - flag byte 0x7E, escape byte 0x7D, escaped byte = byte ^ 0x20;
//! - bytes that need escaping: 0x11 (XON), 0x13 (XOFF), 0x7D, 0x7E, 0xF8 (`kFlagSpecial`);
//! - FCS-16: init 0xFFFF, reflected polynomial 0x8408 (CRC-16/X-25), complemented at the end,
//!   appended low byte first; the FCS bytes themselves are escaped like any other byte;
//! - a received frame is good when the running FCS over payload + FCS equals 0xF0B8.

pub const FLAG: u8 = 0x7e;
pub const ESCAPE: u8 = 0x7d;
pub const INIT_FCS: u16 = 0xffff;
pub const GOOD_FCS: u16 = 0xf0b8;

fn needs_escape(b: u8) -> bool {
    matches!(b, 0x11 | 0x13 | 0x7d | 0x7e | 0xf8)
}

/// One step of the FCS-16 (bitwise, no table; checked against OpenThread's table in the tests).
pub fn update_fcs(fcs: u16, byte: u8) -> u16 {
    let mut c = fcs ^ u16::from(byte);
    for _ in 0..8 {
        c = if c & 1 != 0 { (c >> 1) ^ 0x8408 } else { c >> 1 };
    }
    c
}

/// FCS to append for `data` (already complemented, to be sent low byte first).
pub fn fcs(data: &[u8]) -> u16 {
    data.iter().fold(INIT_FCS, |f, &b| update_fcs(f, b)) ^ 0xffff
}

fn push_escaped(out: &mut Vec<u8>, b: u8) {
    if needs_escape(b) {
        out.push(ESCAPE);
        out.push(b ^ 0x20);
    } else {
        out.push(b);
    }
}

/// Wrap a payload in an HDLC-lite frame: FLAG, escaped payload, escaped FCS, FLAG.
pub fn encode(payload: &[u8]) -> Vec<u8> {
    let f = fcs(payload);
    let mut out = Vec::with_capacity(payload.len() + 6);
    out.push(FLAG);
    for &b in payload {
        push_escaped(&mut out, b);
    }
    push_escaped(&mut out, (f & 0xff) as u8);
    push_escaped(&mut out, (f >> 8) as u8);
    out.push(FLAG);
    out
}

/// Streaming decoder, same state machine as `Hdlc::Decoder` in hdlc.cpp. Frames with a bad FCS
/// or shorter than the FCS are dropped silently.
pub struct Decoder {
    synced: bool,
    escaped: bool,
    buf: Vec<u8>,
    fcs: u16,
}

const MAX_FRAME: usize = 2048;

impl Default for Decoder {
    fn default() -> Self {
        Self::new()
    }
}

impl Decoder {
    pub fn new() -> Self {
        Decoder { synced: false, escaped: false, buf: Vec::new(), fcs: INIT_FCS }
    }

    /// Feed one byte. Returns a complete, FCS-checked frame (without FCS) when one ends here.
    pub fn feed(&mut self, byte: u8) -> Option<Vec<u8>> {
        if !self.synced {
            if byte == FLAG {
                self.synced = true;
                self.escaped = false;
                self.buf.clear();
                self.fcs = INIT_FCS;
            }
            return None;
        }
        if self.escaped {
            self.escaped = false;
            self.push(byte ^ 0x20);
            return None;
        }
        match byte {
            ESCAPE => {
                self.escaped = true;
                None
            }
            FLAG => {
                let mut out = None;
                if self.buf.len() >= 2 && self.fcs == GOOD_FCS {
                    let n = self.buf.len() - 2;
                    out = Some(self.buf[..n].to_vec());
                }
                self.buf.clear();
                self.fcs = INIT_FCS;
                out
            }
            b => {
                self.push(b);
                None
            }
        }
    }

    fn push(&mut self, b: u8) {
        if self.buf.len() >= MAX_FRAME {
            self.synced = false;
            self.buf.clear();
            return;
        }
        self.fcs = update_fcs(self.fcs, b);
        self.buf.push(b);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verbatim from `sFcsTable` in OpenThread src/lib/hdlc/hdlc.cpp.
    const OT_FCS_TABLE: [u16; 256] = [
        0x0000, 0x1189, 0x2312, 0x329b, 0x4624, 0x57ad, 0x6536, 0x74bf,
        0x8c48, 0x9dc1, 0xaf5a, 0xbed3, 0xca6c, 0xdbe5, 0xe97e, 0xf8f7,
        0x1081, 0x0108, 0x3393, 0x221a, 0x56a5, 0x472c, 0x75b7, 0x643e,
        0x9cc9, 0x8d40, 0xbfdb, 0xae52, 0xdaed, 0xcb64, 0xf9ff, 0xe876,
        0x2102, 0x308b, 0x0210, 0x1399, 0x6726, 0x76af, 0x4434, 0x55bd,
        0xad4a, 0xbcc3, 0x8e58, 0x9fd1, 0xeb6e, 0xfae7, 0xc87c, 0xd9f5,
        0x3183, 0x200a, 0x1291, 0x0318, 0x77a7, 0x662e, 0x54b5, 0x453c,
        0xbdcb, 0xac42, 0x9ed9, 0x8f50, 0xfbef, 0xea66, 0xd8fd, 0xc974,
        0x4204, 0x538d, 0x6116, 0x709f, 0x0420, 0x15a9, 0x2732, 0x36bb,
        0xce4c, 0xdfc5, 0xed5e, 0xfcd7, 0x8868, 0x99e1, 0xab7a, 0xbaf3,
        0x5285, 0x430c, 0x7197, 0x601e, 0x14a1, 0x0528, 0x37b3, 0x263a,
        0xdecd, 0xcf44, 0xfddf, 0xec56, 0x98e9, 0x8960, 0xbbfb, 0xaa72,
        0x6306, 0x728f, 0x4014, 0x519d, 0x2522, 0x34ab, 0x0630, 0x17b9,
        0xef4e, 0xfec7, 0xcc5c, 0xddd5, 0xa96a, 0xb8e3, 0x8a78, 0x9bf1,
        0x7387, 0x620e, 0x5095, 0x411c, 0x35a3, 0x242a, 0x16b1, 0x0738,
        0xffcf, 0xee46, 0xdcdd, 0xcd54, 0xb9eb, 0xa862, 0x9af9, 0x8b70,
        0x8408, 0x9581, 0xa71a, 0xb693, 0xc22c, 0xd3a5, 0xe13e, 0xf0b7,
        0x0840, 0x19c9, 0x2b52, 0x3adb, 0x4e64, 0x5fed, 0x6d76, 0x7cff,
        0x9489, 0x8500, 0xb79b, 0xa612, 0xd2ad, 0xc324, 0xf1bf, 0xe036,
        0x18c1, 0x0948, 0x3bd3, 0x2a5a, 0x5ee5, 0x4f6c, 0x7df7, 0x6c7e,
        0xa50a, 0xb483, 0x8618, 0x9791, 0xe32e, 0xf2a7, 0xc03c, 0xd1b5,
        0x2942, 0x38cb, 0x0a50, 0x1bd9, 0x6f66, 0x7eef, 0x4c74, 0x5dfd,
        0xb58b, 0xa402, 0x9699, 0x8710, 0xf3af, 0xe226, 0xd0bd, 0xc134,
        0x39c3, 0x284a, 0x1ad1, 0x0b58, 0x7fe7, 0x6e6e, 0x5cf5, 0x4d7c,
        0xc60c, 0xd785, 0xe51e, 0xf497, 0x8028, 0x91a1, 0xa33a, 0xb2b3,
        0x4a44, 0x5bcd, 0x6956, 0x78df, 0x0c60, 0x1de9, 0x2f72, 0x3efb,
        0xd68d, 0xc704, 0xf59f, 0xe416, 0x90a9, 0x8120, 0xb3bb, 0xa232,
        0x5ac5, 0x4b4c, 0x79d7, 0x685e, 0x1ce1, 0x0d68, 0x3ff3, 0x2e7a,
        0xe70e, 0xf687, 0xc41c, 0xd595, 0xa12a, 0xb0a3, 0x8238, 0x93b1,
        0x6b46, 0x7acf, 0x4854, 0x59dd, 0x2d62, 0x3ceb, 0x0e70, 0x1ff9,
        0xf78f, 0xe606, 0xd49d, 0xc514, 0xb1ab, 0xa022, 0x92b9, 0x8330,
        0x7bc7, 0x6a4e, 0x58d5, 0x495c, 0x3de3, 0x2c6a, 0x1ef1, 0x0f78,
    ];

    #[test]
    fn bitwise_fcs_matches_openthread_table() {
        // UpdateFcs() in hdlc.cpp: (fcs >> 8) ^ table[(fcs ^ byte) & 0xff]
        for fcs in [0u16, 1, 0xffff, 0x1234, 0xbeef, 0x8408, 0xf0b8] {
            for b in 0..=255u8 {
                let want = (fcs >> 8) ^ OT_FCS_TABLE[((fcs ^ u16::from(b)) & 0xff) as usize];
                assert_eq!(update_fcs(fcs, b), want, "fcs={fcs:#06x} byte={b:#04x}");
            }
        }
    }

    #[test]
    fn crc16_x25_check_value() {
        // CRC-16/X-25 catalogue check value for "123456789" is 0x906E.
        assert_eq!(fcs(b"123456789"), 0x906e);
    }

    #[test]
    fn reset_to_bootloader_frame_matches_docs() {
        // docss/bootloader_and_update.md: 7E 81 01 03 BF BB 7E
        assert_eq!(encode(&[0x81, 0x01, 0x03]), [0x7e, 0x81, 0x01, 0x03, 0xbf, 0xbb, 0x7e]);
        assert_eq!(fcs(&[0x81, 0x01, 0x03]), 0xbbbf);
    }

    #[test]
    fn good_residue() {
        let mut f = INIT_FCS;
        for b in [0x81u8, 0x01, 0x03, 0xbf, 0xbb] {
            f = update_fcs(f, b);
        }
        assert_eq!(f, GOOD_FCS);
    }

    #[test]
    fn escaping_roundtrip() {
        let payload = [0x11u8, 0x13, 0x7d, 0x7e, 0xf8, 0x00, 0xff, 0x20];
        let enc = encode(&payload);
        assert_eq!(&enc[1..3], &[0x7d, 0x31]); // 0x11 ^ 0x20
        assert_eq!(enc[0], FLAG);
        assert_eq!(*enc.last().unwrap(), FLAG);
        // no raw special byte between the flags
        for &b in &enc[1..enc.len() - 1] {
            assert!(!matches!(b, 0x11 | 0x13 | 0x7e | 0xf8));
        }
        let mut d = Decoder::new();
        let got: Vec<_> = enc.iter().filter_map(|&b| d.feed(b)).collect();
        assert_eq!(got, vec![payload.to_vec()]);
    }

    #[test]
    fn fcs_bytes_are_escaped_too() {
        // find payloads whose FCS contains a byte that needs escaping and check the roundtrip
        let mut found = false;
        for a in 0..=255u8 {
            let p = [0x81u8, 0x02, a];
            let f = fcs(&p);
            if needs_escape((f & 0xff) as u8) || needs_escape((f >> 8) as u8) {
                found = true;
                let enc = encode(&p);
                let mut d = Decoder::new();
                let got: Vec<_> = enc.iter().filter_map(|&b| d.feed(b)).collect();
                assert_eq!(got, vec![p.to_vec()]);
            }
        }
        assert!(found);
    }

    #[test]
    fn decoder_drops_bad_fcs_and_resyncs() {
        let mut bad = encode(&[0x81, 0x01, 0x03]);
        let n = bad.len();
        bad[n - 2] ^= 0x01; // corrupt the FCS high byte
        let good = encode(&[0x81, 0x02, 0x02]);
        let mut d = Decoder::new();
        let mut stream = vec![0x00, 0x55]; // garbage before the first flag
        stream.extend(bad);
        stream.extend(&good[1..]); // the closing flag of `bad` doubles as the opening one
        let got: Vec<_> = stream.iter().filter_map(|&b| d.feed(b)).collect();
        assert_eq!(got, vec![vec![0x81, 0x02, 0x02]]);
    }

    #[test]
    fn decoder_ignores_empty_frames_and_back_to_back_flags() {
        let mut d = Decoder::new();
        let mut stream = vec![FLAG, FLAG, FLAG];
        stream.extend(encode(&[1, 2, 3]));
        let got: Vec<_> = stream.iter().filter_map(|&b| d.feed(b)).collect();
        assert_eq!(got, vec![vec![1, 2, 3]]);
    }
}
