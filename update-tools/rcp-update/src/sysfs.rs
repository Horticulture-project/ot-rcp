//! USB serial port lookup by VID:PID through sysfs (no libudev, so the binary stays static).

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsbTty {
    pub path: String,
    pub vid: u16,
    pub pid: u16,
}

pub fn parse_vidpid(s: &str) -> Result<(u16, u16), String> {
    let (v, p) = s.split_once(':').ok_or_else(|| format!("expected VID:PID, got '{s}'"))?;
    let v = u16::from_str_radix(v.trim(), 16).map_err(|e| format!("bad VID '{v}': {e}"))?;
    let p = u16::from_str_radix(p.trim(), 16).map_err(|e| format!("bad PID '{p}': {e}"))?;
    Ok((v, p))
}

#[cfg(target_os = "linux")]
pub fn list_usb_ttys() -> Vec<UsbTty> {
    use std::fs;
    use std::path::Path;
    let mut out = Vec::new();
    let Ok(rd) = fs::read_dir("/sys/class/tty") else { return out };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if !(name.starts_with("ttyACM") || name.starts_with("ttyUSB")) {
            continue;
        }
        let Ok(dev) = fs::canonicalize(e.path().join("device")) else { continue };
        for anc in dev.ancestors().take(6) {
            let (v, p) = (anc.join("idVendor"), anc.join("idProduct"));
            if Path::new(&v).exists() && Path::new(&p).exists() {
                let rd = |f: &Path| {
                    fs::read_to_string(f).ok().and_then(|s| u16::from_str_radix(s.trim(), 16).ok())
                };
                if let (Some(vid), Some(pid)) = (rd(&v), rd(&p)) {
                    out.push(UsbTty { path: format!("/dev/{name}"), vid, pid });
                }
                break;
            }
        }
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

#[cfg(not(target_os = "linux"))]
pub fn list_usb_ttys() -> Vec<UsbTty> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vidpid() {
        assert_eq!(parse_vidpid("1915:521f"), Ok((0x1915, 0x521f)));
        assert_eq!(parse_vidpid("1915:0000"), Ok((0x1915, 0)));
        assert!(parse_vidpid("1915").is_err());
        assert!(parse_vidpid("zz:1").is_err());
    }
}
