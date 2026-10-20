//! rcp-update: serial helper for the RCP update scripts. See ../README.md.
//!
//! stdout carries only machine-readable results (a tty path, a version string, hex bytes),
//! everything else goes to stderr. Exit code 0 = success, 1 = operation failed, 2 = usage error.

mod hdlc;
mod smp;
mod spinel;
mod sysfs;

use clap::{Parser, Subcommand, ValueEnum};
use serialport::{ClearBuffer, DataBits, FlowControl, Parity, SerialPort, StopBits};
use std::io::{Read, Write};
use std::process::ExitCode;
use std::time::{Duration, Instant};

#[derive(Parser)]
#[command(version, about = "Serial helper for the RCP update scripts (touch, Spinel reset, SMP probe, version query)")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Clone, ValueEnum)]
enum FrameKind {
    ResetBootloader,
    Version,
}

#[derive(Subcommand)]
enum Cmd {
    /// Print a Spinel HDLC frame as hex (no device access).
    Frame { kind: FrameKind },
    /// List USB serial ports (ttyACM*/ttyUSB*) with VID:PID, read from sysfs.
    List,
    /// 1200-baud touch: open at 1200 8N1, hold, drop DTR, close.
    Touch {
        #[arg(long)]
        port: String,
        #[arg(long, default_value_t = 1200)]
        baud: u32,
        /// Time the port is held open with DTR high before it is dropped.
        #[arg(long, default_value_t = 150)]
        hold_ms: u64,
    },
    /// Wait for a USB tty with the given VID:PID and print its path.
    FindTty {
        #[arg(long, value_name = "VID:PID")]
        vid_pid: String,
        #[arg(long, default_value_t = 10.0)]
        timeout: f64,
        /// Ignore this tty path (for example the pre-touch port).
        #[arg(long)]
        exclude: Option<String>,
    },
    /// Send the Spinel RESET (bootloader) frame. No reply is expected.
    ResetBootloader {
        #[arg(long)]
        port: String,
        #[arg(long)]
        baud: u32,
        /// RTS/CTS hardware flow control (460800 variants).
        #[arg(long)]
        flow: bool,
    },
    /// Query the RCP version (Spinel PROP NCP_VERSION) and print it.
    Version {
        #[arg(long)]
        port: String,
        #[arg(long)]
        baud: u32,
        #[arg(long)]
        flow: bool,
        /// Total time to keep asking, seconds.
        #[arg(long, default_value_t = 5.0)]
        timeout: f64,
    },
    /// MCUboot serial recovery liveness probe (SMP echo, 8N1, no flow control).
    Probe {
        #[arg(long)]
        port: String,
        #[arg(long, default_value_t = 115_200)]
        baud: u32,
        #[arg(long, default_value = "ping")]
        message: String,
        /// Per attempt reply timeout, seconds.
        #[arg(long, default_value_t = 1.5)]
        timeout: f64,
        /// Keep retrying (once per second) for this many seconds in total.
        #[arg(long, default_value_t = 0.0)]
        wait: f64,
    },
}

type Res<T> = Result<T, String>;

fn secs(s: f64) -> Duration {
    Duration::from_millis((s.max(0.0) * 1000.0) as u64)
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02X}")).collect::<Vec<_>>().join(" ")
}

fn open(port: &str, baud: u32, flow: bool, timeout: Duration) -> Res<Box<dyn SerialPort>> {
    serialport::new(port, baud)
        .data_bits(DataBits::Eight)
        .parity(Parity::None)
        .stop_bits(StopBits::One)
        .flow_control(if flow { FlowControl::Hardware } else { FlowControl::None })
        .timeout(timeout)
        .open()
        .map_err(|e| {
            let hint = match e.kind() {
                serialport::ErrorKind::NoDevice => " (no such device)",
                serialport::ErrorKind::Io(std::io::ErrorKind::PermissionDenied) => {
                    " (permission denied: add the user to the 'dialout' group or run as root)"
                }
                _ => " (busy? stop otbr-agent and anything else holding the port)",
            };
            format!("cannot open {port} at {baud} 8N1{}: {e}{hint}", if flow { " +RTS/CTS" } else { "" })
        })
}

fn touch(port: &str, baud: u32, hold_ms: u64) -> Res<()> {
    if baud != 1200 {
        eprintln!("warning: touch baud is {baud}, the firmware only reacts to 1200");
    }
    let mut p = open(port, baud, false, Duration::from_millis(100))?;
    // DTR is raised by the kernel on open; make it explicit so the later drop is a real edge.
    let _ = p.write_data_terminal_ready(true);
    std::thread::sleep(Duration::from_millis(hold_ms.max(100)));
    // Drop DTR explicitly (does not depend on HUPCL), keep the 1200 baud line coding for the
    // >=60 ms the firmware wants to see DTR low, then close.
    let _ = p.write_data_terminal_ready(false);
    std::thread::sleep(Duration::from_millis(150));
    drop(p);
    eprintln!("touch done on {port} (1200 baud, held {hold_ms} ms)");
    Ok(())
}

fn find_tty(vid_pid: &str, timeout: Duration, exclude: Option<&str>) -> Res<String> {
    let (vid, pid) = sysfs::parse_vidpid(vid_pid)?;
    if !cfg!(target_os = "linux") {
        return Err("find-tty needs Linux sysfs".into());
    }
    let start = Instant::now();
    loop {
        for t in sysfs::list_usb_ttys() {
            if t.vid == vid && t.pid == pid && Some(t.path.as_str()) != exclude {
                // wait until udev has given us access to the node (permissions are applied after creation)
                let ready_by = Instant::now() + Duration::from_secs(3);
                while std::fs::OpenOptions::new().read(true).write(true).open(&t.path).is_err()
                    && Instant::now() < ready_by
                {
                    std::thread::sleep(Duration::from_millis(100));
                }
                std::thread::sleep(Duration::from_millis(300));
                return Ok(t.path);
            }
        }
        if start.elapsed() >= timeout {
            return Err(format!("no USB tty with {vid:04x}:{pid:04x} within {:.1}s", timeout.as_secs_f64()));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn reset_bootloader(port: &str, baud: u32, flow: bool) -> Res<()> {
    if baud == 1200 {
        return Err("refusing baud 1200 for Spinel (that is the dongle touch rate)".into());
    }
    let frame = spinel::reset_to_bootloader_frame();
    let mut p = open(port, baud, flow, Duration::from_secs(2))?;
    let _ = p.clear(ClearBuffer::All);
    eprintln!("sending {} at {baud} 8N1{}", hex(&frame), if flow { " +RTS/CTS" } else { "" });
    p.write_all(&frame).map_err(|e| format!("write failed: {e}"))?;
    p.flush().map_err(|e| format!("flush failed: {e}"))?;
    // let the last bytes leave the shifter before the port is closed
    std::thread::sleep(Duration::from_millis(100));
    Ok(())
}

fn version(port: &str, baud: u32, flow: bool, timeout: Duration) -> Res<String> {
    if baud == 1200 {
        return Err("refusing baud 1200 for Spinel (that would reboot the dongle into DFU)".into());
    }
    let mut p = open(port, baud, flow, Duration::from_millis(100))?;
    let _ = p.clear(ClearBuffer::Input);
    let req = spinel::version_request_frame();
    let deadline = Instant::now() + timeout;
    let mut dec = hdlc::Decoder::new();
    let mut buf = [0u8; 256];
    while Instant::now() < deadline {
        p.write_all(&req).map_err(|e| format!("write failed: {e}"))?;
        let _ = p.flush();
        let attempt_end = (Instant::now() + Duration::from_millis(1000)).min(deadline);
        while Instant::now() < attempt_end {
            match p.read(&mut buf) {
                Ok(n) => {
                    for &b in &buf[..n] {
                        if let Some(frame) = dec.feed(b) {
                            if let Some(v) = spinel::parse_version(&frame, 1) {
                                return Ok(v);
                            }
                        }
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(e) => return Err(format!("read failed: {e}")),
            }
        }
    }
    Err(format!("no Spinel version reply from {port} at {baud} within {:.1}s", timeout.as_secs_f64()))
}

fn probe_once(port: &str, baud: u32, message: &str, timeout: Duration) -> Res<String> {
    let mut p = open(port, baud, false, Duration::from_millis(100))?;
    let _ = p.clear(ClearBuffer::Input);
    let seq = (Instant::now().elapsed().subsec_nanos() & 0xff) as u8 ^ (std::process::id() as u8);
    p.write_all(&smp::build_echo_request(seq, message)).map_err(|e| format!("write failed: {e}"))?;
    let _ = p.flush();
    let end = Instant::now() + timeout;
    let mut raw = Vec::new();
    let mut buf = [0u8; 256];
    while Instant::now() < end {
        match p.read(&mut buf) {
            Ok(n) => raw.extend_from_slice(&buf[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {}
            Err(e) => return Err(format!("read failed: {e}")),
        }
        match smp::parse_response(&raw) {
            smp::Parsed::Incomplete => {}
            smp::Parsed::Bad(why) => return Err(format!("bad SMP reply: {why}")),
            smp::Parsed::Echo { seq: s, text, rc } => {
                if s != seq {
                    return Err("SMP reply with wrong sequence number".into());
                }
                if let Some(rc) = rc {
                    if rc != 0 {
                        return Err(format!("SMP echo returned rc={rc}"));
                    }
                }
                return Ok(text.unwrap_or_default());
            }
        }
    }
    Err("no SMP reply".into())
}

fn probe(port: &str, baud: u32, message: &str, timeout: Duration, wait: Duration) -> Res<String> {
    let deadline = Instant::now() + wait;
    loop {
        match probe_once(port, baud, message, timeout) {
            Ok(t) => return Ok(t),
            Err(e) => {
                if Instant::now() >= deadline {
                    return Err(e);
                }
                std::thread::sleep(Duration::from_secs(1));
            }
        }
    }
}

fn run(cli: Cli) -> Res<()> {
    match cli.cmd {
        Cmd::Frame { kind } => {
            let f = match kind {
                FrameKind::ResetBootloader => spinel::reset_to_bootloader_frame(),
                FrameKind::Version => spinel::version_request_frame(),
            };
            println!("{}", hex(&f));
        }
        Cmd::List => {
            for t in sysfs::list_usb_ttys() {
                println!("{} {:04x}:{:04x}", t.path, t.vid, t.pid);
            }
        }
        Cmd::Touch { port, baud, hold_ms } => touch(&port, baud, hold_ms)?,
        Cmd::FindTty { vid_pid, timeout, exclude } => {
            println!("{}", find_tty(&vid_pid, secs(timeout), exclude.as_deref())?)
        }
        Cmd::ResetBootloader { port, baud, flow } => reset_bootloader(&port, baud, flow)?,
        Cmd::Version { port, baud, flow, timeout } => println!("{}", version(&port, baud, flow, secs(timeout))?),
        Cmd::Probe { port, baud, message, timeout, wait } => {
            println!("Echo response: {}", probe(&port, baud, &message, secs(timeout), secs(wait))?)
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("rcp-update: {e}");
            ExitCode::from(1)
        }
    }
}
