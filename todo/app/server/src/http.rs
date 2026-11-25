//! One HTTP/1.1 request per connection, over std::net. Loopback only; the routes live in mod.rs.
use super::js;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};

const HEAD_LIMIT: usize = 16 * 1024;
const BODY_LIMIT: usize = 64 * 1024;
const METHODS: [&str; 9] = ["GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "TRACE", "CONNECT"];

pub struct Request {
    pub method: String,
    /// The normalized path, as `new URL(req.url).pathname` gives it.
    pub path: String,
    query: String,
    headers: Vec<(String, String)>,
    pub http11: bool,
    /// Body bytes that arrived with the head.
    rest: Vec<u8>,
}
pub enum Bad { Closed, Status(u16) }

impl Request {
    /// Every value of a header, in order.
    pub fn all(&self, name: &str) -> Vec<&str> { self.headers.iter().filter(|(n, _)| n == name).map(|(_, v)| v.as_str()).collect() }
    /// The only value of a header; a repeated one matches nothing.
    pub fn only(&self, name: &str) -> Option<&str> { match self.all(name)[..] { [value] => Some(value), _ => None } }
    /// searchParams.get
    pub fn param(&self, name: &str) -> Option<String> {
        self.query.split('&').map(|p| p.split_once('=').unwrap_or((p, ""))).find(|(k, _)| decode(k) == name).map(|(_, v)| decode(v))
    }
    fn length(&self) -> Result<Option<usize>, Bad> {
        match self.all("content-length")[..] {
            [] => Ok(None),
            [value] if !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()) => Ok(Some(value.parse().unwrap_or(usize::MAX))),
            _ => Err(Bad::Status(400)),
        }
    }
    /// The body, None when it is over the limit.
    pub fn body(&mut self, stream: &mut &TcpStream) -> Result<Option<Vec<u8>>, Bad> {
        if self.all("expect").iter().any(|v| v.eq_ignore_ascii_case("100-continue")) && self.rest.is_empty() { let _ = stream.write_all(b"HTTP/1.1 100 Continue\r\n\r\n"); }
        let mut input = Input { bytes: std::mem::take(&mut self.rest), at: 0, stream, until: Instant::now() + Duration::from_secs(300) };
        let length = self.length()?;
        let coding = self.all("transfer-encoding");
        if coding.is_empty() {
            let length = length.unwrap_or(0);
            if length > BODY_LIMIT { return Ok(None); }
            return input.take(length).map(Some);
        }
        if length.is_some() || coding.len() != 1 || !coding[0].eq_ignore_ascii_case("chunked") { return Err(Bad::Status(400)); }
        // Chunk extensions and trailers carry nothing here; together they may not pass a head's size.
        let (mut body, mut spare) = (Vec::new(), HEAD_LIMIT);
        loop {
            let line = input.line()?;
            let size = line.split(';').next().unwrap_or("").trim();
            spare = spare.checked_sub(line.len() - size.len()).ok_or(Bad::Status(413))?;
            if size.is_empty() || size.len() > 8 || !size.bytes().all(|b| b.is_ascii_hexdigit()) { return Err(Bad::Status(400)); }
            let size = usize::from_str_radix(size, 16).map_err(|_| Bad::Status(400))?;
            if size == 0 {
                loop {
                    let trailer = input.line()?;
                    if trailer.is_empty() { return Ok(Some(body)); }
                    spare = spare.checked_sub(trailer.len() + 2).ok_or(Bad::Status(431))?;
                }
            }
            if body.len() + size > BODY_LIMIT { return Ok(None); }
            body.extend(input.take(size)?);
            if !input.line()?.is_empty() { return Err(Bad::Status(400)); }
        }
    }
}

struct Input<'a, 'b> { bytes: Vec<u8>, at: usize, stream: &'a mut &'b TcpStream, until: Instant }
impl Input<'_, '_> {
    fn more(&mut self) -> Result<(), Bad> {
        let mut buffer = [0; 8192];
        if Instant::now() > self.until { return Err(Bad::Status(408)); }
        // What was used is dropped, so a body of any framing keeps only what it still needs.
        self.bytes.drain(..std::mem::take(&mut self.at));
        match self.stream.read(&mut buffer) { Ok(n) if n > 0 => { self.bytes.extend_from_slice(&buffer[..n]); Ok(()) } _ => Err(Bad::Closed) }
    }
    fn take(&mut self, length: usize) -> Result<Vec<u8>, Bad> {
        while self.bytes.len() - self.at < length { self.more()?; }
        self.at += length;
        Ok(self.bytes[self.at - length..self.at].to_vec())
    }
    fn line(&mut self) -> Result<String, Bad> {
        loop {
            if let Some(n) = self.bytes[self.at..].iter().position(|b| *b == b'\n') {
                let line = String::from_utf8_lossy(&self.bytes[self.at..self.at + n]).trim_end_matches('\r').to_string();
                self.at += n + 1;
                return Ok(line);
            }
            if self.bytes.len() - self.at > 1024 { return Err(Bad::Status(400)); }
            self.more()?;
        }
    }
}

fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let (mut out, mut i) = (Vec::with_capacity(bytes.len()), 0);
    while i < bytes.len() {
        let hex = |b: Option<&u8>| b.and_then(|b| (*b as char).to_digit(16));
        match (bytes[i], hex(bytes.get(i + 1)), hex(bytes.get(i + 2))) {
            (b'%', Some(h), Some(l)) => { out.push((h * 16 + l) as u8); i += 3; }
            (b'+', ..) => { out.push(b' '); i += 1; }
            (b, ..) => { out.push(b); i += 1; }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The path and query of a request target: an absolute or `//host` form loses its host, and dot segments are resolved
/// before any route or token check sees the path.
fn target(raw: &str) -> Option<(String, String)> {
    let raw = raw.split('#').next().unwrap_or("");
    let (before, query) = raw.split_once('?').unwrap_or((raw, ""));
    let before = before.replace('\\', "/");
    let lower = before.to_ascii_lowercase();
    let path = match ["http://", "https://"].iter().find(|s| lower.starts_with(**s)).map(|s| s.len()).or(before.starts_with("//").then_some(2)) {
        Some(skip) => { let host = &before[skip..]; host.find('/').map_or("/", |at| &host[at..]).to_string() }
        None if before.starts_with('/') => before,
        None if before.contains(':') => return None,
        None => format!("/{before}"),
    };
    let mut out: Vec<&str> = Vec::new();
    let parts: Vec<&str> = path[1..].split('/').collect();
    for (i, part) in parts.iter().enumerate() {
        let dots = part.to_ascii_lowercase().replace("%2e", ".");
        match dots.as_str() {
            "." => {}
            ".." => { out.pop(); }
            _ => { out.push(part); continue; }
        }
        if i + 1 == parts.len() { out.push(""); }
    }
    Some((format!("/{}", out.join("/")), query.to_string()))
}

/// Reads a head; a connection that sends none in 10 s is closed.
pub fn read_request(stream: &mut &TcpStream) -> Result<Request, Bad> {
    let until = Instant::now() + Duration::from_secs(10);
    let mut head = Vec::new();
    let mut buffer = [0; 4096];
    let end = loop {
        if let Some(at) = head.windows(4).position(|w| w == b"\r\n\r\n") { break at; }
        if head.len() > HEAD_LIMIT { return Err(Bad::Status(431)); }
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() { return Err(Bad::Status(408)); }
        let _ = stream.set_read_timeout(Some(left));
        match stream.read(&mut buffer) { Ok(n) if n > 0 => head.extend_from_slice(&buffer[..n]), _ => return Err(Bad::Closed) }
    };
    if end > HEAD_LIMIT { return Err(Bad::Status(431)); }
    let _ = stream.set_read_timeout(Some(Duration::from_secs(60)));
    let rest = head.split_off(end + 4);
    let bad = || Bad::Status(400);
    // Header bytes outside ASCII are kept as Latin-1, as Node does.
    let text: String = head[..end].iter().map(|b| *b as char).collect();
    let mut lines = text.split("\r\n");
    let mut parts = lines.next().unwrap_or("").split(' ');
    let (Some(method), Some(url), Some(version), None) = (parts.next(), parts.next(), parts.next(), parts.next()) else { return Err(bad()) };
    if !METHODS.contains(&method) || !matches!(version, "HTTP/1.1" | "HTTP/1.0") || url.bytes().any(|b| b <= b' ' || b == 0x7f) { return Err(bad()); }
    let mut headers = Vec::new();
    for line in lines {
        let (name, value) = line.split_once(':').ok_or_else(bad)?;
        if name.is_empty() || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b)) { return Err(bad()); }
        if value.bytes().any(|b| b < b' ' && b != b'\t' || b == 0x7f) { return Err(bad()); }
        headers.push((name.to_ascii_lowercase(), js::trim(value).to_string()));
    }
    let (path, query) = target(url).ok_or_else(bad)?;
    Ok(Request { method: method.into(), path, query, headers, http11: version == "HTTP/1.1", rest })
}

pub const HEADERS: &str = "Content-Security-Policy: default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\
X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nCache-Control: no-store\r\n";

pub fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", 408 => "Request Timeout",
        409 => "Conflict", 413 => "Payload Too Large", 431 => "Request Header Fields Too Large", 503 => "Service Unavailable", _ => "Error",
    }
}
/// Answers and closes the connection; `body` is left out for HEAD.
pub fn answer(stream: &mut &TcpStream, request: &Request, status: u16, kind: &str, content: &[u8]) {
    let head = format!("HTTP/1.1 {status} {}\r\n{HEADERS}Content-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", reason(status), content.len());
    if stream.write_all(head.as_bytes()).is_ok() && request.method != "HEAD" { let _ = stream.write_all(content); }
    // A plain GET has nothing left to read.
    let bodyless = request.method == "GET" && request.rest.is_empty() && request.all("content-length").is_empty() && request.all("transfer-encoding").is_empty();
    if !bodyless { finish(stream); }
}
/// A request that cannot be read, as Node answers it.
pub fn refuse(stream: &mut &TcpStream, status: u16) {
    let _ = stream.write_all(format!("HTTP/1.1 {status} {}\r\nConnection: close\r\n\r\n", reason(status)).as_bytes());
    finish(stream);
}
/// Closes after reading what the client still sends for a moment: unread bytes would reset the connection and lose the answer.
fn finish(stream: &mut &TcpStream) {
    let _ = stream.flush();
    if stream.shutdown(std::net::Shutdown::Write).is_err() { return; }
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let until = Instant::now() + Duration::from_secs(2);
    let mut sink = [0; 8192];
    while Instant::now() < until { match stream.read(&mut sink) { Ok(n) if n > 0 => {} _ => break } }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_target_is_normalized_before_any_check() {
        let path = |raw| target(raw).map(|(p, _)| p);
        for (raw, expected) in [("/", "/"), ("/x/../api/items", "/api/items"), ("/x/%2E%2e/api/items?a=1#b", "/api/items"), ("http://evil/api/items", "/api/items"),
            ("//evil/api/items", "/api/items"), ("\\x\\..\\api\\items", "/api/items"), ("/api/./items", "/api/items"), ("/a/..", "/"), ("http://evil", "/"), ("/%61pi/items", "/%61pi/items")] {
            assert_eq!(path(raw).as_deref(), Some(expected), "{raw}");
        }
        assert_eq!(path("foo:bar"), None);
        assert_eq!(decode("a%20b+c%zz"), "a b c%zz");
    }
}
