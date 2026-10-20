//! Minimal SMP-over-serial client, only enough for the MCUboot "echo" liveness probe.
//! Framing as implemented by mcumgr-client v0.1.0 (`src/transfer.rs`: `encode_request`,
//! `transceive`) and MCUboot `boot_serial.c`:
//!   packet = len(u16 BE, covers header+body+crc) | 8-byte SMP header | CBOR body | CRC-16/XMODEM (BE)
//!   line   = 0x06 0x09 (first) or 0x04 0x14 (continuation) + base64(chunk) + '\n'
//! SMP header: op, flags, len(u16 BE), group(u16 BE), seq, id. Echo = op 2 (write), group 0, id 0,
//! body {"d": "<text>"}; response op 3 with body {"r": "<text>"}.

pub fn crc16_xmodem(data: &[u8]) -> u16 {
    let mut crc: u16 = 0;
    for &b in data {
        crc ^= u16::from(b) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 { (crc << 1) ^ 0x1021 } else { crc << 1 };
        }
    }
    crc
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn b64_encode(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        out.push(B64[(n >> 18) as usize & 63]);
        out.push(B64[(n >> 12) as usize & 63]);
        out.push(if c.len() > 1 { B64[(n >> 6) as usize & 63] } else { b'=' });
        out.push(if c.len() > 2 { B64[n as usize & 63] } else { b'=' });
    }
    out
}

pub fn b64_decode(text: &[u8]) -> Option<Vec<u8>> {
    let val = |c: u8| -> Option<u32> { B64.iter().position(|&x| x == c).map(|p| p as u32) };
    #[allow(unknown_lints, clippy::manual_is_multiple_of)]
    let bad_len = text.len() % 4 != 0;
    if bad_len {
        return None;
    }
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    for q in text.chunks(4) {
        let pad = q.iter().rev().take_while(|&&c| c == b'=').count();
        if pad > 2 {
            return None;
        }
        let mut n: u32 = 0;
        for (i, &c) in q.iter().enumerate() {
            n <<= 6;
            if i < 4 - pad {
                n |= val(c)?;
            }
        }
        out.push((n >> 16) as u8);
        if pad < 2 {
            out.push((n >> 8) as u8);
        }
        if pad < 1 {
            out.push(n as u8);
        }
    }
    Some(out)
}

/// CBOR `{"d": message}` (only for messages shorter than 24 bytes... or up to 255 bytes).
fn cbor_echo_body(message: &str) -> Vec<u8> {
    let m = message.as_bytes();
    assert!(m.len() < 256);
    let mut b = vec![0xa1, 0x61, b'd'];
    if m.len() < 24 {
        b.push(0x60 | m.len() as u8);
    } else {
        b.push(0x78);
        b.push(m.len() as u8);
    }
    b.extend_from_slice(m);
    b
}

/// Complete serial line(s) for an echo request. Single line for short messages.
pub fn build_echo_request(seq: u8, message: &str) -> Vec<u8> {
    let body = cbor_echo_body(message);
    let mut pkt = vec![2u8, 0];
    pkt.extend_from_slice(&(body.len() as u16).to_be_bytes());
    pkt.extend_from_slice(&0u16.to_be_bytes());
    pkt.push(seq);
    pkt.push(0); // echo
    pkt.extend_from_slice(&body);
    let crc = crc16_xmodem(&pkt);
    pkt.extend_from_slice(&crc.to_be_bytes());
    let mut framed = (pkt.len() as u16).to_be_bytes().to_vec();
    framed.extend_from_slice(&pkt);
    let b64 = b64_encode(&framed);
    // mcumgr-client uses 128 byte lines: 4 bytes of designator/newline overhead -> 124 base64 chars.
    // MCUboot's CONFIG_BOOT_MAX_LINE_INPUT_LEN is 128 by default.
    let mut out = Vec::new();
    for (i, chunk) in b64.chunks(124).enumerate() {
        out.extend_from_slice(if i == 0 { &[0x06, 0x09] } else { &[0x04, 0x14] });
        out.extend_from_slice(chunk);
        out.push(b'\n');
    }
    out
}

#[derive(Debug, PartialEq, Eq)]
pub enum Parsed {
    /// Not enough data yet.
    Incomplete,
    /// Echo response accepted; text is the "r" value if it could be decoded.
    Echo { seq: u8, text: Option<String>, rc: Option<i64> },
    /// Complete packet but not an acceptable echo response.
    Bad(&'static str),
}

/// Try to parse a (possibly partial) serial stream as one SMP response.
pub fn parse_response(raw: &[u8]) -> Parsed {
    let Some(start) = raw.windows(2).position(|w| w == [0x06, 0x09]) else {
        return Parsed::Incomplete;
    };
    let mut b64 = Vec::new();
    let mut rest = &raw[start..];
    let mut first = true;
    loop {
        let want: [u8; 2] = if first { [0x06, 0x09] } else { [0x04, 0x14] };
        if rest.len() < 2 {
            break;
        }
        if rest[..2] != want {
            return Parsed::Bad("bad line designator");
        }
        let Some(nl) = rest.iter().position(|&c| c == b'\n') else {
            return Parsed::Incomplete;
        };
        b64.extend_from_slice(&rest[2..nl]);
        rest = &rest[nl + 1..];
        first = false;
        // Is the packet complete? decode what we have
        if let Some(dec) = b64_decode(&b64) {
            if dec.len() >= 2 {
                let len = usize::from(u16::from_be_bytes([dec[0], dec[1]]));
                if dec.len() - 2 >= len {
                    return finish(&dec[2..2 + len]);
                }
            }
        }
    }
    Parsed::Incomplete
}

fn finish(pkt: &[u8]) -> Parsed {
    if pkt.len() < 8 + 2 {
        return Parsed::Bad("packet too short");
    }
    let (data, crc) = pkt.split_at(pkt.len() - 2);
    if crc16_xmodem(data) != u16::from_be_bytes([crc[0], crc[1]]) {
        return Parsed::Bad("wrong checksum");
    }
    let (op, group, seq, id) = (data[0] & 7, u16::from_be_bytes([data[4], data[5]]), data[6], data[7]);
    if op != 3 || group != 0 || id != 0 {
        return Parsed::Bad("not an echo response");
    }
    let body = &data[8..];
    let (text, rc) = parse_cbor_map(body);
    Parsed::Echo { seq, text, rc }
}

/// Very small CBOR reader: a definite-length map with text keys; picks "r" (text) and "rc" (int).
fn parse_cbor_map(b: &[u8]) -> (Option<String>, Option<i64>) {
    let mut text = None;
    let mut rc = None;
    let Some((&first, mut p)) = b.split_first() else { return (None, None) };
    let indefinite = first == 0xbf;
    let mut n = if first & 0xe0 == 0xa0 { usize::from(first & 0x1f) } else if indefinite { usize::MAX } else { return (None, None) };
    if n == 24 {
        return (None, None);
    }
    while n > 0 {
        if indefinite && p.first() == Some(&0xff) {
            break;
        }
        let Some((key, q)) = take_text(p) else { break };
        p = q;
        match p.first() {
            Some(&h) if h & 0xe0 == 0x60 => {
                let Some((v, q)) = take_text(p) else { break };
                if key == "r" {
                    text = Some(v);
                }
                p = q;
            }
            Some(&h) if h & 0xe0 == 0x00 && (h & 0x1f) < 24 => {
                if key == "rc" {
                    rc = Some(i64::from(h & 0x1f));
                }
                p = &p[1..];
            }
            Some(&0x18) if p.len() >= 2 => {
                if key == "rc" {
                    rc = Some(i64::from(p[1]));
                }
                p = &p[2..];
            }
            _ => break, // unsupported value type: stop, keep what we have
        }
        n -= 1;
    }
    (text, rc)
}

fn take_text(p: &[u8]) -> Option<(String, &[u8])> {
    let h = *p.first()?;
    if h & 0xe0 != 0x60 {
        return None;
    }
    let (len, hl) = match h & 0x1f {
        l @ 0..=23 => (usize::from(l), 1),
        24 => (usize::from(*p.get(1)?), 2),
        _ => return None,
    };
    let s = p.get(hl..hl + len)?;
    Some((String::from_utf8(s.to_vec()).ok()?, &p[hl + len..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc_check_value() {
        assert_eq!(crc16_xmodem(b"123456789"), 0x31c3);
    }

    #[test]
    fn base64_vectors() {
        assert_eq!(b64_encode(b""), b"");
        assert_eq!(b64_encode(b"f"), b"Zg==");
        assert_eq!(b64_encode(b"fo"), b"Zm8=");
        assert_eq!(b64_encode(b"foo"), b"Zm9v");
        assert_eq!(b64_encode(b"foobar"), b"Zm9vYmFy");
        for s in [&b""[..], b"f", b"fo", b"foo", b"foob", b"fooba", b"foobar"] {
            assert_eq!(b64_decode(&b64_encode(s)).unwrap(), s);
        }
        assert!(b64_decode(b"Zm9").is_none());
        assert!(b64_decode(b"Zm9!").is_none());
    }

    #[test]
    fn echo_request_matches_independent_reference() {
        // Reference produced with a separate Python implementation (struct + base64 + CRC-XMODEM):
        // pkt = 00 12 | 02 00 0008 0000 2a 00 | a1 61 64 64 70 69 6e 67 | 96 36
        let want = b"\x06\x09ABICAAAIAAAqAKFhZGRwaW5nljY=\n";
        assert_eq!(build_echo_request(0x2a, "ping"), want);
    }

    #[test]
    fn echo_response_parse() {
        let raw = b"noise\x06\x09ABIDAAAIAAAqAKFhcmRwaW5nqXc=\n";
        assert_eq!(
            parse_response(raw),
            Parsed::Echo { seq: 0x2a, text: Some("ping".into()), rc: None }
        );
    }

    #[test]
    fn partial_and_corrupt_responses() {
        assert_eq!(parse_response(b""), Parsed::Incomplete);
        assert_eq!(parse_response(b"\x06\x09ABIDAAAIAAAq"), Parsed::Incomplete);
        // corrupt one base64 character inside the CRC-protected region
        let r = parse_response(b"\x06\x09ABIDAAAIAAAqAKFhcmRwaW5oqXc=\n");
        assert!(matches!(r, Parsed::Bad(_)), "{r:?}");
        // a request echoed back (op 2) is not a response
        let req = build_echo_request(1, "x");
        assert!(matches!(parse_response(&req), Parsed::Bad("not an echo response")));
    }

    #[test]
    fn long_message_is_split_into_lines() {
        let msg = "a".repeat(120);
        let req = build_echo_request(7, &msg);
        let lines: Vec<_> = req.split(|&c| c == b'\n').filter(|l| !l.is_empty()).collect();
        assert!(lines.len() >= 2);
        assert_eq!(&lines[0][..2], &[0x06, 0x09]);
        assert_eq!(&lines[1][..2], &[0x04, 0x14]);
        assert!(lines.iter().all(|l| l.len() < 128));
    }
}
