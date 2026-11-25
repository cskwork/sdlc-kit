//! The JavaScript, Node path and time behaviour todo.md depends on, and the few system calls std does not cover.
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// `\s` in a JavaScript regex, which is also what trim() removes.
pub fn is_space(c: char) -> bool {
    matches!(c, '\t'..='\r' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}')
}
pub fn trim(text: &str) -> &str { text.trim_matches(is_space) }
/// Whether `(.*)$` in a JavaScript regex takes all of `text`: `.` stops at a line terminator.
pub fn dot_all(text: &str) -> bool { !text.contains(['\n', '\r', '\u{2028}', '\u{2029}']) }
/// `.length`
pub fn units(text: &str) -> usize { text.chars().map(char::len_utf16).sum() }
/// `.slice(0, max)` as Node then writes it: half of a pair becomes U+FFFD.
pub fn slice(text: &str, max: usize) -> String {
    let (mut out, mut used) = (String::new(), 0);
    for c in text.chars() {
        if used + c.len_utf16() > max { if used < max { out.push('\u{fffd}'); } break; }
        used += c.len_utf16();
        out.push(c);
    }
    out
}
/// `\b`: a place between a word character and anything else.
fn word(b: Option<u8>) -> bool { b.is_some_and(|b| b.is_ascii_alphanumeric() || b == b'_') }
/// `/\bapprove(\s+| )(intent|plan)\b/`: the gate a status action asks for, '' when none.
pub fn gate(action: &str, one_space: bool) -> &'static str {
    for (at, _) in action.match_indices("approve") {
        if at > 0 && word(Some(action.as_bytes()[at - 1])) { continue; }
        let rest = &action[at + 7..];
        let after = if one_space { rest.strip_prefix(' ').unwrap_or(rest) } else { rest.trim_start_matches(is_space) };
        if after.len() == rest.len() { continue; }
        for name in ["intent", "plan"] {
            if after.starts_with(name) && !word(after.as_bytes().get(name.len()).copied()) { return name; }
        }
    }
    ""
}

// ---------- paths (node:path) ----------
pub fn is_absolute(path: &str) -> bool {
    if cfg!(windows) {
        let b = path.as_bytes();
        matches!(b.first(), Some(b'/' | b'\\')) || (b.len() > 2 && b[0].is_ascii_alphabetic() && b[1] == b':' && matches!(b[2], b'/' | b'\\'))
    } else { path.starts_with('/') }
}
/// path.dirname, for the absolute or relative file paths used here.
pub fn dirname(path: &str) -> String {
    match Path::new(path).parent() { Some(dir) if !dir.as_os_str().is_empty() => dir.to_string_lossy().into_owned(), Some(_) => ".".into(), None => path.into() }
}
pub fn basename(path: &str) -> String { Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default() }
/// path.join of a normalized result.
pub fn join(base: &str, parts: &[&str]) -> String {
    if cfg!(windows) {
        let mut path = std::path::PathBuf::from(base);
        for part in parts { path.push(part); }
        return normalize(&path.to_string_lossy().replace('/', "\\"), '\\');
    }
    let mut all: Vec<&str> = vec![base];
    all.extend_from_slice(parts);
    normalize(&all.into_iter().filter(|p| !p.is_empty()).collect::<Vec<_>>().join("/"), '/')
}
fn normalize(path: &str, sep: char) -> String {
    // A Windows drive or share root is kept as written; only what follows it is normalized.
    let root = if sep == '\\' && path.as_bytes().get(1) == Some(&b':') { 2 } else if sep == '\\' && path.starts_with("\\\\") { 1 } else { 0 };
    let (prefix, rest) = path.split_at(root);
    let absolute = rest.starts_with(sep);
    let mut out: Vec<&str> = Vec::new();
    for part in rest.split(sep) {
        match part {
            "" | "." => {}
            ".." => { if out.last().is_some_and(|l| *l != "..") { out.pop(); } else if !absolute { out.push(".."); } }
            part => out.push(part),
        }
    }
    let mut body = out.join(&sep.to_string());
    if body.is_empty() && !absolute && prefix.is_empty() { body.push('.'); }
    if rest.len() > 1 && rest.ends_with(sep) && !body.is_empty() { body.push(sep); }
    format!("{prefix}{}{body}", if absolute { sep.to_string() } else { String::new() })
}
/// path.resolve of a relative path.
pub fn resolve(path: &str) -> String {
    let cwd = std::env::current_dir().map(|d| d.to_string_lossy().into_owned()).unwrap_or_default();
    let joined = join(&cwd, &[path]);
    let end = joined.trim_end_matches(if cfg!(windows) { '\\' } else { '/' });
    if end.is_empty() { joined } else { end.to_string() }
}
/// An environment variable as Node reads it; undecodable bytes become U+FFFD.
pub fn env(name: &str) -> Option<String> { std::env::var_os(name).map(|v| v.to_string_lossy().into_owned()) }
/// os.homedir(): the variable when set (even empty), else the account's own folder.
pub fn home() -> String {
    // Windows: os.homedir() refuses a USERPROFILE too short to be a folder; a relative list must not come of it.
    let set = if cfg!(windows) { env("USERPROFILE").filter(|home| home.len() > 2) } else { env("HOME") };
    set.unwrap_or_else(account_home)
}
#[cfg(unix)]
fn account_home() -> String {
    let mut buffer = vec![0u8; 16 * 1024];
    // SAFETY: getpwuid_r fills the struct and buffer it is given; pw_dir points into the buffer.
    unsafe {
        let mut entry: libc::passwd = std::mem::zeroed();
        let mut found = std::ptr::null_mut();
        let code = libc::getpwuid_r(libc::geteuid(), &mut entry, buffer.as_mut_ptr().cast(), buffer.len(), &mut found);
        if code != 0 || found.is_null() || entry.pw_dir.is_null() { return String::new(); }
        std::ffi::CStr::from_ptr(entry.pw_dir).to_string_lossy().into_owned()
    }
}
#[cfg(windows)]
fn account_home() -> String {
    let mut buffer = [0u16; 1024];
    let mut size = buffer.len() as u32;
    // SAFETY: the token is closed; the buffer holds `size` units, its final NUL included.
    unsafe {
        let mut token = std::ptr::null_mut();
        if win::OpenProcessToken(win::GetCurrentProcess(), 0x0008, &mut token) == 0 { return String::new(); } // TOKEN_QUERY
        let got = win::GetUserProfileDirectoryW(token, buffer.as_mut_ptr(), &mut size);
        win::CloseHandle(token);
        if got == 0 { return String::new(); }
    }
    String::from_utf16_lossy(&buffer[..buffer.iter().position(|u| *u == 0).unwrap_or(0)])
}

// ---------- random, hashes ----------
pub fn random<const N: usize>() -> Result<[u8; N], String> {
    let mut bytes = [0; N];
    getrandom::fill(&mut bytes).map_err(|e| format!("no random bytes: {e}"))?;
    Ok(bytes)
}
pub fn hex(bytes: &[u8]) -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() }
/// randomUUID
pub fn uuid() -> Result<String, String> {
    let mut b = random::<16>()?;
    b[6] = b[6] & 0x0f | 0x40;
    b[8] = b[8] & 0x3f | 0x80;
    let h = hex(&b);
    Ok(format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..]))
}
/// HMAC-SHA256 (RFC 2104) of `message` under `key`, in hex.
pub fn hmac(key: &[u8], message: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut block = [0u8; 64];
    if key.len() > 64 { block[..32].copy_from_slice(&Sha256::digest(key)); } else { block[..key.len()].copy_from_slice(key); }
    let inner = Sha256::new().chain_update(block.map(|b| b ^ 0x36)).chain_update(message).finalize();
    hex(&Sha256::new().chain_update(block.map(|b| b ^ 0x5c)).chain_update(inner).finalize())
}
/// Whether two secrets are equal, in a time that does not tell how far they agree.
pub fn same(a: &[u8], b: &[u8]) -> bool { a.len() == b.len() && a.iter().zip(b).fold(0, |diff, (x, y)| diff | (x ^ y)) == 0 }
pub fn sha256(bytes: &[u8]) -> String { use sha2::Digest; hex(&sha2::Sha256::digest(bytes)) }
/// SHA-1, only for item ids (no SHA-1 crate is in the lock file).
pub fn sha1(bytes: &[u8]) -> String {
    let mut h: [u32; 5] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0];
    let mut data = bytes.to_vec();
    data.push(0x80);
    while data.len() % 64 != 56 { data.push(0); }
    data.extend_from_slice(&((bytes.len() as u64) * 8).to_be_bytes());
    for block in data.chunks_exact(64) {
        let mut w = [0u32; 80];
        for (i, c) in block.chunks_exact(4).enumerate() { w[i] = u32::from_be_bytes([c[0], c[1], c[2], c[3]]); }
        for i in 16..80 { w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1); }
        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (i, word) in w.iter().enumerate() {
            let (f, k) = match i / 20 { 0 => (b & c | !b & d, 0x5a827999), 1 => (b ^ c ^ d, 0x6ed9eba1), 2 => (b & c | b & d | c & d, 0x8f1bbcdc), _ => (b ^ c ^ d, 0xca62c1d6u32) };
            let next = a.rotate_left(5).wrapping_add(f).wrapping_add(e).wrapping_add(k).wrapping_add(*word);
            (e, d, c, b, a) = (d, c, b.rotate_left(30), a, next);
        }
        for (slot, v) in h.iter_mut().zip([a, b, c, d, e]) { *slot = slot.wrapping_add(v); }
    }
    h.iter().map(|v| format!("{v:08x}")).collect()
}

// ---------- time ----------
pub fn now_ms() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0) }
/// Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm), and back.
fn days(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
}
fn civil(days: i64) -> (i64, i64, i64) {
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, doy - (153 * mp + 2) / 5 + 1)
}
/// new Date(ms).toISOString()
pub fn iso(ms: i64) -> String {
    let (y, m, d) = civil(ms.div_euclid(86_400_000));
    let t = ms.rem_euclid(86_400_000);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{:03}Z", t / 3_600_000, t / 60_000 % 60, t / 1000 % 60, t % 1000)
}
fn numbers(text: &str, pattern: &str) -> Option<Vec<i64>> {
    let (mut out, mut digits) = (Vec::new(), String::new());
    if text.len() != pattern.len() { return None; }
    for (c, p) in text.bytes().zip(pattern.bytes()) {
        if p == b'0' { if !c.is_ascii_digit() { return None; } digits.push(c as char); }
        else { if c != p { return None; } if !digits.is_empty() { out.push(std::mem::take(&mut digits).parse().ok()?); } }
    }
    if !digits.is_empty() { out.push(digits.parse().ok()?); }
    Some(out)
}
fn real_date(y: i64, m: i64, d: i64) -> bool { (1..=12).contains(&m) && d >= 1 && civil(days(y, m, d)) == (y, m, d) }
/// Date.parse of the ISO time toISOString writes; None is another form, for Node to read.
pub fn parse_iso(text: &str) -> Option<i64> {
    let n = numbers(text, "0000-00-00T00:00:00.000Z")?;
    if n.len() != 7 || !real_date(n[0], n[1], n[2]) || n[3] > 23 || n[4] > 59 || n[5] > 59 { return None; }
    Some(((days(n[0], n[1], n[2]) * 24 + n[3]) * 60 + n[4]) * 60_000 + n[5] * 1000 + n[6])
}
/// Date.parse of an event stamp's local "YYYY-MM-DD HH:MM"; None is not a real time.
pub fn parse_stamp(text: &str) -> Option<i64> {
    let n = numbers(text, "0000-00-00 00:00")?;
    if n.len() != 5 || !real_date(n[0], n[1], n[2]) || n[3] > 23 || n[4] > 59 { return None; }
    Some(local_to_ms(n[0], n[1], n[2], n[3], n[4]))
}
/// An event's local "YYYY-MM-DD HH:MM".
pub fn stamp() -> String {
    let (y, m, d, h, min) = local_now();
    format!("{y}-{m:02}-{d:02} {h:02}:{min:02}")
}
#[cfg(unix)]
fn local_now() -> (i64, i64, i64, i64, i64) {
    let seconds = (now_ms() / 1000) as libc::time_t;
    // SAFETY: localtime_r fills the zeroed tm it is given.
    let tm = unsafe { let mut tm: libc::tm = std::mem::zeroed(); libc::localtime_r(&seconds, &mut tm); tm };
    (tm.tm_year as i64 + 1900, tm.tm_mon as i64 + 1, tm.tm_mday as i64, tm.tm_hour as i64, tm.tm_min as i64)
}
#[cfg(unix)]
fn local_to_ms(y: i64, m: i64, d: i64, h: i64, min: i64) -> i64 {
    // SAFETY: mktime reads and normalizes the tm it is given; tm_isdst -1 asks it to decide.
    unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        (tm.tm_year, tm.tm_mon, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_isdst) = ((y - 1900) as i32, (m - 1) as i32, d as i32, h as i32, min as i32, -1);
        libc::mktime(&mut tm) as i64 * 1000
    }
}
#[cfg(windows)]
mod win {
    use std::ffi::c_void;
    #[repr(C)]
    #[derive(Default)]
    pub struct SystemTime { pub y: u16, pub m: u16, pub dow: u16, pub d: u16, pub h: u16, pub min: u16, pub s: u16, pub ms: u16 }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        pub fn GetLocalTime(time: *mut SystemTime);
        pub fn OpenProcess(access: u32, inherit: i32, pid: u32) -> *mut c_void;
        pub fn GetExitCodeProcess(process: *mut c_void, code: *mut u32) -> i32;
        pub fn CloseHandle(handle: *mut c_void) -> i32;
        pub fn GetCurrentProcess() -> *mut c_void;
        pub fn LocalFree(memory: *mut c_void) -> *mut c_void;
    }
    #[link(name = "userenv")]
    unsafe extern "system" {
        pub fn GetUserProfileDirectoryW(token: *mut c_void, out: *mut u16, size: *mut u32) -> i32;
    }
    #[link(name = "advapi32")]
    unsafe extern "system" {
        pub fn OpenProcessToken(process: *mut c_void, access: u32, token: *mut *mut c_void) -> i32;
        pub fn GetTokenInformation(token: *mut c_void, class: u32, out: *mut c_void, size: u32, needed: *mut u32) -> i32;
        pub fn ConvertSidToStringSidW(sid: *mut c_void, text: *mut *mut u16) -> i32;
        pub fn ConvertStringSecurityDescriptorToSecurityDescriptorW(text: *const u16, revision: u32, out: *mut *mut c_void, size: *mut u32) -> i32;
        pub fn SetFileSecurityW(file: *const u16, what: u32, descriptor: *mut c_void) -> i32;
    }
}
#[cfg(windows)]
fn local_now() -> (i64, i64, i64, i64, i64) {
    let mut t = win::SystemTime::default();
    // SAFETY: fills the struct it is given.
    unsafe { win::GetLocalTime(&mut t) };
    (t.y as i64, t.m as i64, t.d as i64, t.h as i64, t.min as i64)
}
#[cfg(windows)]
fn local_to_ms(y: i64, m: i64, d: i64, h: i64, min: i64) -> i64 {
    // Uses the offset in force now; it only ages a command run, which Windows never starts.
    let (ny, nm, nd, nh, nmin) = local_now();
    let wall = |y, m, d, h, min| ((days(y, m, d) * 24 + h) * 60 + min) * 60_000;
    now_ms() - now_ms() % 60_000 - (wall(ny, nm, nd, nh, nmin) - wall(y, m, d, h, min))
}

/// Leaves a file to its user alone (a protected access list), as mode 0600 does elsewhere.
#[cfg(windows)]
pub fn owner_only(file: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    let failed = || Err(std::io::Error::last_os_error());
    let wide = |text: &std::ffi::OsStr| text.encode_wide().chain([0]).collect::<Vec<u16>>();
    // SAFETY: every pointer is to a live buffer of the size given; what Windows allocates is freed below.
    unsafe {
        let mut token = std::ptr::null_mut();
        if win::OpenProcessToken(win::GetCurrentProcess(), 0x0008, &mut token) == 0 { return failed(); } // TOKEN_QUERY
        // TOKEN_USER: a pointer to the SID, then the SID; u64 keeps it aligned.
        let (mut user, mut needed) = ([0u64; 32], 0);
        let got = win::GetTokenInformation(token, 1, user.as_mut_ptr().cast(), std::mem::size_of_val(&user) as u32, &mut needed);
        win::CloseHandle(token);
        if got == 0 { return failed(); }
        let mut sid: *mut u16 = std::ptr::null_mut();
        if win::ConvertSidToStringSidW(*user.as_ptr().cast::<*mut std::ffi::c_void>(), &mut sid) == 0 { return failed(); }
        let length = (0..).take_while(|i| *sid.add(*i) != 0).count();
        let name = String::from_utf16_lossy(std::slice::from_raw_parts(sid, length));
        win::LocalFree(sid.cast());
        let mut descriptor = std::ptr::null_mut();
        let rules = wide(format!("D:P(A;;FA;;;{name})").as_ref());
        if win::ConvertStringSecurityDescriptorToSecurityDescriptorW(rules.as_ptr(), 1, &mut descriptor, std::ptr::null_mut()) == 0 { return failed(); }
        let set = win::SetFileSecurityW(wide(file.as_os_str()).as_ptr(), 0x8000_0004, descriptor); // the list, protected
        let result = if set == 0 { failed() } else { Ok(()) };
        win::LocalFree(descriptor);
        result
    }
}

// ---------- processes ----------
/// process.kill(pid, 0): whether the process exists (a process of another user counts).
#[cfg(unix)]
pub fn alive(pid: u64) -> bool {
    let Ok(pid) = i32::try_from(pid) else { return false };
    // SAFETY: signal 0 only checks.
    unsafe { libc::kill(pid, 0) == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH) }
}
#[cfg(windows)]
pub fn alive(pid: u64) -> bool {
    let Ok(pid) = u32::try_from(pid) else { return false };
    const QUERY: u32 = 0x1000;
    // SAFETY: the handle is checked and closed.
    unsafe {
        let handle = win::OpenProcess(QUERY, 0, pid);
        if handle.is_null() { return std::io::Error::last_os_error().raw_os_error() == Some(5); }
        let mut code = 0;
        let known = win::GetExitCodeProcess(handle, &mut code);
        win::CloseHandle(handle);
        known == 0 || code == 259
    }
}
/// Node's name and words for a system error.
pub fn errno(error: &std::io::Error) -> (String, &'static str) {
    #[cfg(unix)]
    if let Some(raw) = error.raw_os_error() {
        let known = match raw {
            libc::ENOENT => ("ENOENT", "no such file or directory"),
            libc::EACCES => ("EACCES", "permission denied"),
            libc::EPERM => ("EPERM", "operation not permitted"),
            libc::EEXIST => ("EEXIST", "file already exists"),
            libc::EISDIR => ("EISDIR", "illegal operation on a directory"),
            libc::ENOTDIR => ("ENOTDIR", "not a directory"),
            libc::ENOTEMPTY => ("ENOTEMPTY", "directory not empty"),
            libc::ENOSPC => ("ENOSPC", "no space left on device"),
            libc::EROFS => ("EROFS", "read-only file system"),
            libc::EBUSY => ("EBUSY", "resource busy or locked"),
            libc::EMFILE => ("EMFILE", "too many open files"),
            libc::ENFILE => ("ENFILE", "file table overflow"),
            libc::ENAMETOOLONG => ("ENAMETOOLONG", "name too long"),
            libc::ELOOP => ("ELOOP", "too many symbolic links encountered"),
            libc::EXDEV => ("EXDEV", "cross-device link not permitted"),
            libc::ENOEXEC => ("ENOEXEC", "exec format error"),
            libc::E2BIG => ("E2BIG", "argument list too long"),
            libc::ENOMEM => ("ENOMEM", "not enough memory"),
            libc::EAGAIN => ("EAGAIN", "resource temporarily unavailable"),
            libc::ETXTBSY => ("ETXTBSY", "text file is busy"),
            libc::EIO => ("EIO", "i/o error"),
            libc::EINVAL => ("EINVAL", "invalid argument"),
            _ => ("", ""),
        };
        if !known.0.is_empty() { return (known.0.into(), known.1); }
    }
    #[cfg(windows)]
    match error.raw_os_error() {
        Some(5 | 303) => return ("EPERM".into(), "operation not permitted"),
        Some(32 | 33) => return ("EBUSY".into(), "resource busy or locked"),
        Some(3 | 267) => return ("ENOENT".into(), "no such file or directory"),
        _ => {}
    }
    match error.kind() {
        std::io::ErrorKind::NotFound => ("ENOENT".into(), "no such file or directory"),
        std::io::ErrorKind::PermissionDenied => ("EPERM".into(), "operation not permitted"),
        std::io::ErrorKind::AlreadyExists => ("EEXIST".into(), "file already exists"),
        _ => (error.raw_os_error().map_or("ERROR".into(), |n| format!("E{n}")), "system error"),
    }
}

// ---------- showing a command exactly (todo/status.mjs) ----------
fn hidden(c: char) -> bool {
    matches!(c as u32, 0..=0x1f | 0x7f..=0x9f | 0xad | 0x34f | 0x61c | 0x115f | 0x1160 | 0x17b4 | 0x17b5 | 0x180e | 0x200b..=0x200f
        | 0x2028..=0x202e | 0x2060..=0x206f | 0x3164 | 0xfe00..=0xfe0f | 0xfeff | 0xfff9..=0xfffb)
}
/// Hidden characters (and, with `blanks`, runs of four or more spaces) as bash escapes; the flag says whether any were.
pub fn visible(text: &str, blanks: bool) -> (String, bool) {
    let (mut out, mut escaped, mut spaces) = (String::new(), false, 0);
    let flush = |out: &mut String, spaces: &mut usize, escaped: &mut bool| {
        let long = blanks && *spaces >= 4;
        *escaped |= long;
        out.push_str(&if long { "\\x20" } else { " " }.repeat(*spaces));
        *spaces = 0;
    };
    for c in text.chars() {
        if c == ' ' { spaces += 1; continue; }
        flush(&mut out, &mut spaces, &mut escaped);
        if !hidden(c) { out.push(c); continue; }
        escaped = true;
        match c {
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x100 => out.push_str(&format!("\\x{:02x}", c as u32)),
            c => out.push_str(&format!("\\u{:04x}", c as u32)),
        }
    }
    flush(&mut out, &mut spaces, &mut escaped);
    (out, escaped)
}
/// One argument as a POSIX shell word.
pub fn shell_word(text: &str) -> String {
    if !text.is_empty() && text.bytes().all(|b| b.is_ascii_alphanumeric() || b"_@%+=:,./-".contains(&b)) { return text.into(); }
    if !visible(text, true).1 { return format!("'{}'", text.replace('\'', "'\\''")); }
    format!("$'{}'", visible(&text.replace('\\', "\\\\").replace('\'', "\\'"), true).0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_node_for_hashes_time_paths_and_shell_words() {
        assert_eq!(sha1(b""), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
        assert_eq!(sha1(&[b'a'; 200]), "e61cfffe0d9195a525fc6cf06ca2d77119c24a40");
        assert_eq!(sha256(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(iso(1794452645678), "2026-11-12T03:04:05.678Z");
        assert_eq!(parse_iso("2026-11-12T03:04:05.678Z"), Some(1794452645678));
        assert_eq!(parse_iso("2026-02-30T03:04:05.678Z"), None);
        assert!((now_ms() - parse_stamp(&stamp()).unwrap()).abs() < 61_000);
        #[cfg(windows)]
        {
            assert_eq!(join(r"C:\a\b", &["work", "..", "x/PLAN.md"]), r"C:\a\b\x\PLAN.md");
            assert_eq!(join(r"\\srv\share", &["x"]), r"\\srv\share\x");
            assert_eq!(dirname("C:/a/todo.md"), "C:/a");
            assert!(is_absolute(r"C:\x") && is_absolute("/x") && !is_absolute("C:x"));
            assert_eq!(resolve("./x"), join(&std::env::current_dir().unwrap().to_string_lossy(), &["x"]));
            assert!(alive(std::process::id().into()) && !alive(0x7fff_fffc));
        }
        #[cfg(unix)]
        {
            assert_eq!(join("/a//b/", &["work", "../x", "PLAN.md"]), "/a/b/x/PLAN.md");
            assert_eq!(dirname("todo.md"), ".");
        }
        assert_eq!(shell_word("a b'c"), "'a b'\\''c'");
        assert_eq!(shell_word("a    b\u{202e}\\"), "$'a\\x20\\x20\\x20\\x20b\\u202e\\\\'");
        assert_eq!((gate("x approve  plan now", false), gate("approve  plan", true), gate("preapprove plan", false), gate("approve plans", false)), ("plan", "", "", ""));
        assert_eq!((slice("a😀b", 2), slice("a😀b", 3)), ("a\u{fffd}".into(), "a😀".into()));
    }
    #[test]
    fn hmac_matches_rfc_4231() {
        assert_eq!(hmac(b"Jefe", b"what do ya want for nothing?"), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
        // A key longer than a block is hashed first (RFC 4231 test case 6).
        assert_eq!(hmac(&[0xaa; 131], b"Test Using Larger Than Block-Size Key - Hash Key First"), "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
        assert!(same(b"abc", b"abc") && !same(b"abc", b"abd") && !same(b"abc", b"ab"));
    }

}
