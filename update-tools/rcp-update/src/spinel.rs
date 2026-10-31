//! The few Spinel messages this tool needs. Values from OpenThread `src/lib/spinel/spinel.h`
//! (main branch, fetched 2026-10-21): `SPINEL_HEADER_FLAG` 0x80, header = flag | IID << 4 | TID,
//! `SPINEL_CMD_RESET` 1, `SPINEL_CMD_PROP_VALUE_GET` 2, `SPINEL_CMD_PROP_VALUE_IS` 6,
//! `SPINEL_RESET_BOOTLOADER` 3, `SPINEL_PROP_NCP_VERSION` 2. Command and property ids are
//! "packed unsigned integers" (7 bits per byte, little endian, bit 7 = continuation).

use crate::hdlc;

pub const HEADER_FLAG: u8 = 0x80;
pub const CMD_RESET: u32 = 1;
pub const CMD_PROP_VALUE_GET: u32 = 2;
pub const CMD_PROP_VALUE_IS: u32 = 6;
pub const RESET_BOOTLOADER: u8 = 3;
pub const PROP_NCP_VERSION: u32 = 2;

pub fn header(iid: u8, tid: u8) -> u8 {
    HEADER_FLAG | ((iid & 0x3) << 4) | (tid & 0xf)
}

pub fn pack_uint(mut v: u32, out: &mut Vec<u8>) {
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

/// Returns (value, bytes consumed).
pub fn unpack_uint(data: &[u8]) -> Option<(u32, usize)> {
    let mut v: u32 = 0;
    for (i, &b) in data.iter().enumerate().take(5) {
        v |= u32::from(b & 0x7f) << (7 * i);
        if b & 0x80 == 0 {
            return Some((v, i + 1));
        }
    }
    None
}

pub fn reset_payload(tid: u8, reset_type: u8) -> Vec<u8> {
    let mut p = vec![header(0, tid)];
    pack_uint(CMD_RESET, &mut p);
    p.push(reset_type);
    p
}

pub fn prop_get_payload(tid: u8, prop: u32) -> Vec<u8> {
    let mut p = vec![header(0, tid)];
    pack_uint(CMD_PROP_VALUE_GET, &mut p);
    pack_uint(prop, &mut p);
    p
}

/// HDLC frame for "reset to bootloader" (TID 1): 7E 81 01 03 BF BB 7E.
pub fn reset_to_bootloader_frame() -> Vec<u8> {
    hdlc::encode(&reset_payload(1, RESET_BOOTLOADER))
}

/// HDLC frame for "get NCP_VERSION" (TID 1): 7E 81 02 02 5E 80 7E.
pub fn version_request_frame() -> Vec<u8> {
    hdlc::encode(&prop_get_payload(1, PROP_NCP_VERSION))
}

pub struct PropIs<'a> {
    pub header: u8,
    pub prop: u32,
    pub value: &'a [u8],
}

/// Parse a decoded Spinel frame as `CMD_PROP_VALUE_IS`; `None` for any other frame.
pub fn parse_prop_is(frame: &[u8]) -> Option<PropIs<'_>> {
    let (&hdr, rest) = frame.split_first()?;
    if hdr & HEADER_FLAG == 0 {
        return None;
    }
    let (cmd, n) = unpack_uint(rest)?;
    if cmd != CMD_PROP_VALUE_IS {
        return None;
    }
    let rest = &rest[n..];
    let (prop, n) = unpack_uint(rest)?;
    Some(PropIs { header: hdr, prop, value: &rest[n..] })
}

/// The value of NCP_VERSION is a NUL-terminated UTF-8 string.
pub fn parse_version(frame: &[u8], expect_tid: u8) -> Option<String> {
    let p = parse_prop_is(frame)?;
    if p.prop != PROP_NCP_VERSION || (p.header & 0x0f) != (expect_tid & 0x0f) {
        return None;
    }
    let end = p.value.iter().position(|&b| b == 0).unwrap_or(p.value.len());
    String::from_utf8(p.value[..end].to_vec()).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames() {
        assert_eq!(reset_to_bootloader_frame(), [0x7e, 0x81, 0x01, 0x03, 0xbf, 0xbb, 0x7e]);
        assert_eq!(version_request_frame(), [0x7e, 0x81, 0x02, 0x02, 0x5e, 0x80, 0x7e]);
    }

    #[test]
    fn header_bits() {
        assert_eq!(header(0, 1), 0x81);
        assert_eq!(header(1, 2), 0x92);
        assert_eq!(header(3, 15), 0xbf);
    }

    #[test]
    fn packed_uint() {
        for v in [0u32, 1, 127, 128, 300, 16383, 16384, 2_097_151, 0x0fff_ffff] {
            let mut o = Vec::new();
            pack_uint(v, &mut o);
            assert_eq!(unpack_uint(&o), Some((v, o.len())));
        }
        let mut o = Vec::new();
        pack_uint(300, &mut o);
        assert_eq!(o, [0xac, 0x02]);
        assert_eq!(unpack_uint(&[0x80, 0x80]), None);
    }

    #[test]
    fn version_response() {
        let mut p = vec![0x81, 0x06, 0x02];
        p.extend_from_slice(b"OPENTHREAD/1.4.0; NRF52840; Oct 21 2026 10:00:00\0");
        let wire = hdlc::encode(&p);
        let mut d = hdlc::Decoder::new();
        let frames: Vec<_> = wire.iter().filter_map(|&b| d.feed(b)).collect();
        assert_eq!(frames.len(), 1);
        assert_eq!(
            parse_version(&frames[0], 1).as_deref(),
            Some("OPENTHREAD/1.4.0; NRF52840; Oct 21 2026 10:00:00")
        );
        // wrong TID, other property and other command are ignored
        assert_eq!(parse_version(&frames[0], 2), None);
        assert_eq!(parse_version(&[0x81, 0x06, 0x00, 0x00], 1), None);
        assert_eq!(parse_version(&[0x80, 0x06, 0x00, 0x00], 1), None);
        assert!(parse_prop_is(&[0x81, 0x07, 0x02]).is_none());
        assert!(parse_prop_is(&[]).is_none());
        assert!(parse_prop_is(&[0x01, 0x06, 0x02]).is_none()); // header flag missing
    }
}
