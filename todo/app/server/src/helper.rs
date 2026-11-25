//! Questions only JavaScript answers exactly: unusual URLs and dates, and V8's own error words that land in
//! todo.md. Each is one short-lived Node process, asked only for input the Rust code does not decide itself.
use super::core::Fail;
use super::json::{self, object, Json};
use std::collections::HashMap;
use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::Mutex;

struct Config { node: String, core: String }
static CONFIG: Mutex<Option<Config>> = Mutex::new(None);
static ANSWERS: Mutex<Option<HashMap<String, Json>>> = Mutex::new(None);

/// The node program and the kit's core.mjs.
pub fn configure(node: &str, core: &std::path::Path) {
    *CONFIG.lock().unwrap_or_else(|e| e.into_inner()) = Some(Config { node: node.into(), core: core.to_string_lossy().into_owned() });
}

const SCRIPT: &str = r#"
const { pathToFileURL } = require('node:url');
let text = '';
process.stdin.on('data', chunk => { text += chunk; }).on('end', async () => {
  const { kind, value, extra } = JSON.parse(text);
  let out = null;
  if (kind === 'url') {
    const core = await import(pathToFileURL(process.argv[1]).href);
    try { if (/^https?:$/.test(new URL(value).protocol)) out = core.linkLabel(value); } catch {}
  } else if (kind === 'date') { const at = Date.parse(value); out = Number.isNaN(at) ? null : at; }
  else if (kind === 'jsonError') { try { JSON.parse(value); out = ''; } catch (error) { out = error.message; } }
  else if (kind === 'status') {
    try {
      const current = JSON.parse(value).features.find(f => f.slug === extra);
      if (!current || !current.state) throw new Error(`feature not found: ${extra}`);
      out = '';
    } catch (error) { out = error.message; }
  }
  process.stdout.write(JSON.stringify(out));
});
"#;

fn ask(kind: &str, value: &str, extra: &str) -> Result<Json, Fail> {
    let key = format!("{kind}\0{extra}\0{value}");
    let cached = kind == "url" || kind == "date";
    if cached {
        if let Some(answer) = ANSWERS.lock().unwrap_or_else(|e| e.into_inner()).as_ref().and_then(|a| a.get(&key)) { return Ok(answer.clone()); }
    }
    let (node, core) = match CONFIG.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        Some(config) => (config.node.clone(), config.core.clone()),
        None => return Err(Fail::new("no node configured")),
    };
    let failed = |why: String| Fail::new(format!("{node} could not check a {kind} in the to-do list: {why}"));
    let mut command = Command::new(super::run::on_path(&node));
    command.arg("-e").arg(SCRIPT).arg(&core).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    super::no_window(&mut command);
    let mut child = command.spawn().map_err(|e| failed(e.to_string()))?;
    let input = object(vec![("kind", Json::str(kind)), ("value", Json::str(value)), ("extra", Json::str(extra))]).stringify();
    let mut stdin = child.stdin.take();
    // Written from its own thread: a long value must not wait on the answer.
    let writer = std::thread::spawn(move || { if let Some(mut pipe) = stdin.take() { let _ = pipe.write_all(input.as_bytes()); } });
    let output = child.wait_with_output().map_err(|e| failed(e.to_string()))?;
    let _ = writer.join();
    if !output.status.success() { return Err(failed(output.status.to_string())); }
    let answer = json::parse(&String::from_utf8_lossy(&output.stdout)).ok_or_else(|| failed("no answer".into()))?;
    if cached {
        let mut answers = ANSWERS.lock().unwrap_or_else(|e| e.into_inner());
        let answers = answers.get_or_insert_with(HashMap::new);
        if answers.len() >= 512 { answers.clear(); }
        answers.insert(key, answer.clone());
    }
    Ok(answer)
}

/// Date.parse
pub fn date(text: &str) -> Option<i64> {
    if let Some(at) = super::js::parse_iso(text) { return Some(at); }
    match ask("date", text, "") { Ok(Json::Num(at)) => Some(at as i64), _ => None }
}
/// The message JSON.parse throws.
pub fn json_error(text: &str) -> String { ask("jsonError", text, "").ok().and_then(|v| v.text()).unwrap_or_else(|| "invalid JSON".into()) }
/// The message core.readStatus records for output it cannot use.
pub fn status_error(stdout: &str, slug: &str) -> Result<String, Fail> { Ok(ask("status", stdout, slug)?.text().unwrap_or_default()) }
/// linkLabel of an http(s) URL, None for anything else.
pub fn link_label(url: &str) -> Result<Option<String>, Fail> {
    match quick(url) {
        Quick::Label(label) => Ok(Some(label)),
        Quick::Not => Ok(None),
        Quick::Valid | Quick::Ask => Ok(ask("url", url, "")?.text()),
    }
}
/// Whether linkValue keeps the URL.
pub fn is_link(url: &str) -> Result<bool, Fail> {
    match quick(url) { Quick::Label(_) | Quick::Valid => Ok(true), Quick::Not => Ok(false), Quick::Ask => Ok(ask("url", url, "")?.text().is_some()) }
}

/// What a plain look at a URL settles: its label, only that it is a web link, that it is none, or nothing.
#[derive(Debug, PartialEq)]
enum Quick { Label(String), Valid, Not, Ask }

fn quick(url: &str) -> Quick {
    let lower = url.to_ascii_lowercase();
    let Some(scheme) = ["https:", "http:"].into_iter().find(|s| lower.starts_with(s)) else {
        // The URL parser ignores control characters, so only plain text is surely not a web link.
        return if url.bytes().all(|b| (0x21..0x7f).contains(&b)) { Quick::Not } else { Quick::Ask };
    };
    let Some(rest) = lower[scheme.len()..].strip_prefix("//") else { return Quick::Ask };
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let (host, port) = rest[..end].split_once(':').unwrap_or((&rest[..end], ""));
    if host.is_empty() || rest[..end].ends_with(':') || !plain_host(host) { return Quick::Ask; }
    if !port.is_empty() && (port.starts_with('0') || port.len() > 5 || !port.bytes().all(|b| b.is_ascii_digit()) || port.parse::<u32>().is_ok_and(|p| p > 65535)) { return Quick::Ask; }
    let after = &url[url.len() - (rest.len() - end)..];
    let path = &after[..after.find(['?', '#']).unwrap_or(after.len())];
    let simple = path.bytes().all(|b| b.is_ascii_alphanumeric() || b"._~/:@!$&()*+,;=%-".contains(&b));
    // A dot segment or a percent-encoded one would be resolved first.
    if !simple || path.contains("/.") || path.to_ascii_lowercase().contains("%2e") { return Quick::Valid; }
    let tail = path.strip_suffix('/').unwrap_or(path);
    if let Some((before, last)) = tail.rsplit_once('/') { if before.ends_with("/browse") && !last.is_empty() { return Quick::Label(last.into()); } }
    let parts: Vec<&str> = tail.split('/').collect();
    if host == "github.com" && parts.len() == 5 && parts[1..].iter().all(|p| !p.is_empty()) && matches!(parts[3], "issues" | "pull") && parts[4].bytes().all(|b| b.is_ascii_digit()) {
        return Quick::Label(format!("{}#{}", parts[2], parts[4]));
    }
    let shown = match (scheme, port) { (_, "") | ("http:", "80") | ("https:", "443") => host.to_string(), _ => format!("{host}:{port}") };
    Quick::Label(shown)
}

/// A lower-case host the URL parser keeps as written: plain labels, or a dotted decimal address.
fn plain_host(host: &str) -> bool {
    let labels: Vec<&str> = host.split('.').collect();
    if labels.iter().any(|l| l.is_empty() || l.starts_with("xn--") || !l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')) { return false; }
    if labels.last().is_some_and(|l| l.as_bytes()[0].is_ascii_alphabetic()) { return true; }
    labels.len() == 4 && labels.iter().all(|l| (*l == "0" || !l.starts_with('0')) && l.parse::<u8>().is_ok() && l.bytes().all(|b| b.is_ascii_digit()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_urls_need_no_node() {
        let label = |text: &str| Quick::Label(text.into());
        assert_eq!(quick("https://acme.example/browse/WEB-1"), label("WEB-1"));
        assert_eq!(quick("HTTPS://Acme.Example:443/x?q=/browse/1"), label("acme.example"));
        assert_eq!(quick("https://github.com/a/b/pull/12/"), label("b#12"));
        assert_eq!(quick("http://127.0.0.1:8080"), label("127.0.0.1:8080"));
        assert_eq!(quick("https://x.example/%ED%95%9C/browse/K-1/"), label("K-1"));
        assert_eq!(quick("https://x.example/한글"), Quick::Valid);
        assert_eq!(quick("ftp://x/y"), Quick::Not);
        for odd in ["http:x", "https://한글.kr/", "https://1.2.3/", "https://a..b/", "https://u@h/", "https://x:/", "https://x:080/", "\u{1}https://x", "https://"] { assert_eq!(quick(odd), Quick::Ask, "{odd}"); }
    }
}
