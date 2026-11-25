//! The to-do list on disk: a port of todo/core.mjs, which the Node CLI keeps using on the same files. The text
//! format, version hashes and lock protocol must stay byte-for-byte the same; tests/todo-rust-core.test.mjs compares.
use super::helper;
use super::js::{self, dirname, join, stamp};
use super::json::{self, object, Json, Text};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Write};
#[cfg(windows)]
use std::path::Path;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

const HEADER: &str = "# To-do\n\n<!-- sdlc-kit to-do. Agents work Open items top-down and stop at one waiting for you. One item per \"- [ ]\" line; its indented lines are fields and history. -->\n\n";
pub const RELATIVE_PROJECT: &str = "relative project path: write an absolute or ~/ path";
pub const CHANGED: &str = "This item changed. Reload and try again.";
pub const FIX_REQUEST: &str = "fix requested";

/// An error as the HTTP answer gives it: status 0 is an error core.mjs throws without one (400).
#[derive(Debug)]
pub struct Fail { pub status: u16, pub message: String, pub kind: Kind }
#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Kind { Plain, LockLost, SyncChanged }
impl Fail {
    pub fn new(message: impl Into<String>) -> Fail { Fail { status: 0, message: message.into(), kind: Kind::Plain } }
    pub fn at<T>(status: u16, message: impl Into<String>) -> Result<T, Fail> { Err(Fail { status, message: message.into(), kind: Kind::Plain }) }
    pub fn kind(kind: Kind) -> Fail { Fail { status: 0, message: String::new(), kind } }
    /// A file system error in Node's words.
    pub fn io(error: &std::io::Error, call: &str, path: &str) -> Fail {
        let (code, words) = js::errno(error);
        Fail::new(format!("{code}: {words}, {call} '{path}'"))
    }
}

#[derive(Clone, PartialEq, Debug)]
pub struct Event { pub at: String, pub who: String, pub what: String }
#[derive(Clone, PartialEq, Debug, Default)]
pub struct Sdlc { pub slug: String, pub phase: String, pub state: String, pub action: String }
#[derive(Clone, PartialEq, Debug)]
pub struct Exec { pub argv: Vec<Text>, pub cwd: Text, pub why: Text }
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Status { Done, Blocked, Waiting, Others, Workable }

#[derive(Clone, Debug)]
pub struct Item {
    /// Which loaded item this is, whatever its id or place becomes.
    pub uid: u64,
    pub id: String,
    pub title: String,
    pub done: bool,
    pub project: String,
    /// (label, url); an empty label is worked out from the URL when written.
    pub link: Option<(String, String)>,
    pub sdlc: Option<Sdlc>,
    pub waiting: String,
    pub others: String,
    pub brief: String,
    pub repos: Vec<String>,
    pub choices: Vec<String>,
    pub pick: Option<usize>,
    pub suggest: String,
    pub run: String,
    pub exec: Option<Exec>,
    /// The structured outcome of the latest run, as its JSON object.
    pub exec_result: Option<Json>,
    pub pin: bool,
    pub events: Vec<Event>,
    pub notes: Vec<String>,
    pub checked_open: bool,
    pub relative: bool,
    pub status: Status,
    pub unread: usize,
    pub fix_requested: bool,
}

static UID: AtomicU64 = AtomicU64::new(1);
impl Item {
    pub fn new(title: String) -> Item {
        Item { uid: UID.fetch_add(1, Ordering::Relaxed), id: String::new(), title, done: false, project: String::new(), link: None, sdlc: None,
            waiting: String::new(), others: String::new(), brief: String::new(), repos: Vec::new(), choices: Vec::new(), pick: None,
            suggest: String::new(), run: String::new(), exec: None, exec_result: None, pin: false, events: Vec::new(), notes: Vec::new(),
            checked_open: false, relative: false, status: Status::Workable, unread: 0, fix_requested: false }
    }
}

pub struct Model { pub preamble: String, pub items: Vec<Item> }
impl Model {
    pub fn by_id(&self, id: &str) -> Option<usize> { self.items.iter().position(|i| i.id == id) }
    fn first_done(&self) -> usize { self.items.iter().position(|i| i.done).unwrap_or(self.items.len()) }
    pub fn insert_before_done(&mut self, item: Item) { let at = self.first_done(); self.items.insert(at, item); }
}

/// A field's text: trimmed, on one line.
fn line(value: &str) -> Result<String, Fail> {
    let text = js::trim(value);
    if text.contains(['\r', '\n']) { return Err(Fail::new("fields must fit on one line")); }
    Ok(text.into())
}
fn drive(text: &str, seps: &str) -> bool {
    let b = text.as_bytes();
    b.len() > 2 && b[0].is_ascii_alphabetic() && b[1] == b':' && seps.as_bytes().contains(&b[2])
}
fn is_relative_project(project: &str) -> bool {
    !project.is_empty() && project != "~" && !(project.starts_with("~/") || project.starts_with('/') || drive(project, "\\/") || project.starts_with("\\\\"))
}
pub fn project_path(project: &str) -> Result<String, Fail> {
    if is_relative_project(project) { return Fail::at(409, RELATIVE_PROJECT); }
    Ok(if project == "~" { js::home() } else if let Some(rest) = project.strip_prefix("~/") { join(&js::home(), &[rest]) } else { project.into() })
}

// ---------- who acts next ----------
fn is_answer(e: &Event) -> bool { (e.who == "human" && e.what.starts_with("reply — ")) || (e.who == "agent" && e.what.starts_with("chat answer — ")) }
fn is_wait(e: &Event) -> bool { (e.who == "agent" && e.what.starts_with("waiting — ")) || (e.who == "sdlc" && e.what.starts_with("NEEDS-HUMAN — ")) }
fn is_read(e: &Event) -> bool { e.who == "agent" && e.what == "read replies" }
/// One past the last matching event, 0 for none.
fn after(item: &Item, matches: impl Fn(&Event) -> bool) -> usize { item.events.iter().rposition(matches).map_or(0, |i| i + 1) }
fn has_replies(item: &Item) -> bool { item.events[after(item, is_wait)..].iter().any(is_answer) }
fn unread(item: &Item) -> usize {
    let from = after(item, is_wait).max(after(item, is_read));
    item.events[from..].iter().filter(|e| e.who == "human" && is_answer(e)).count()
}
fn fix_pending(item: &Item) -> bool { after(item, |e| e.who == "human" && e.what == FIX_REQUEST) > after(item, is_read) }

pub fn derive(item: &mut Item) {
    item.relative = is_relative_project(&item.project);
    let replied = has_replies(item);
    let state = item.sdlc.as_ref().map_or("", |s| s.state.as_str());
    item.unread = unread(item);
    item.status = if item.done { Status::Done }
        else if item.relative || state == "BLOCKED" && (item.waiting.is_empty() || replied) { Status::Blocked }
        else if item.exec.is_some() || (!item.waiting.is_empty() || state == "NEEDS-HUMAN" && item.others.is_empty()) && !replied { Status::Waiting }
        else if !item.others.is_empty() && item.unread == 0 { Status::Others }
        else { Status::Workable };
    item.fix_requested = item.status == Status::Blocked && !item.relative && fix_pending(item);
}
fn item_id(item: &Item) -> String {
    let name = match &item.sdlc { Some(s) if !s.slug.is_empty() => &s.slug, _ => &item.title };
    js::sha1(format!("{}\0{name}", item.project).as_bytes())[..6].into()
}
pub fn identify(model: &mut Model) {
    let mut used = HashSet::new();
    for item in &mut model.items {
        let base = item_id(item);
        let (mut id, mut n) = (base.clone(), 2);
        while used.contains(&id) { id = format!("{base}-{n}"); n += 1; }
        used.insert(id.clone());
        item.id = id;
        derive(item);
    }
}

// ---------- fields ----------
/// linkValue
fn link_value(label: &str, url: &str) -> Result<Option<(String, String)>, Fail> {
    let url = line(url)?;
    if !helper::is_link(&url)? { return Ok(None); }
    // `line(value.label || linkLabel(url))`: a blank label trims to nothing and is worked out when written.
    let label = if label.is_empty() { helper::link_label(&url)?.unwrap_or_default() } else { line(label)? };
    Ok(Some((label, url)))
}
pub struct Parsed { pub title: String, pub project: String, pub link: Option<(String, String)> }
pub fn parse_text(text: &str) -> Result<Parsed, Fail> {
    let text = line(text)?;
    let (mut title, mut project, mut link) = (Vec::new(), String::new(), None);
    for word in text.split(js::is_space).filter(|w| !w.is_empty()) {
        let lower = word.to_ascii_lowercase();
        if link.is_none() && (lower.starts_with("http://") || lower.starts_with("https://")) { link = link_value("", word)?; }
        else if project.is_empty() && (word.starts_with("~/") || word.starts_with('/') || word.starts_with("./") || drive(word, "\\")) { project = word.into(); }
        else { title.push(word); }
    }
    Ok(Parsed { title: title.join(" "), project, link })
}
fn repo_list(value: &str) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    for name in value.split(|c| c == ',' || js::is_space(c)) {
        let ok = name.len() <= 100 && name.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric()) && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._/-".contains(&b));
        if ok && !names.iter().any(|n| n == name) { names.push(name.into()); }
    }
    names
}
fn choice_list(value: &str) -> Vec<String> {
    value.split('|').map(js::trim).filter(|l| !l.is_empty()).take(6).map(str::to_string).collect()
}
fn pick_index(value: &str, choices: &[String]) -> Option<usize> {
    let text = js::trim(value);
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) { return None; }
    text.parse().ok().filter(|n| (1..=choices.len()).contains(n))
}
/// execValue of a line in the list (not strict).
fn exec_value(text: &str) -> Option<Exec> {
    let Json::Obj(entries) = json::parse(text)? else { return None };
    let (mut argv, mut cwd, mut why) = (None, None, Text::default());
    for (key, value) in entries {
        match (key.lossy().as_str(), value) {
            ("argv", Json::Arr(list)) => argv = Some(texts(&list)?),
            ("cwd", Json::Str(text)) => cwd = Some(text),
            ("why", Json::Str(text)) => why = text,
            _ => return None,
        }
    }
    let (argv, cwd) = (argv?, cwd?);
    if argv.is_empty() || argv.iter().any(|a| a.has_any(b"\0")) { return None; }
    if argv[0].is_empty() || argv[0].has_any(b"/\\") && !js::is_absolute(&argv[0].lossy()) { return None; }
    if !js::is_absolute(&cwd.lossy()) || cwd.has_any(b"\r\n\0") { return None; }
    if why.has_any(b"\r\n") || why.units() > 200 { return None; }
    Some(Exec { argv, cwd, why: why.trim() })
}
fn texts(list: &[Json]) -> Option<Vec<Text>> { list.iter().map(|v| match v { Json::Str(text) => Some(text.clone()), _ => None }).collect() }
const RESULT_KEYS: [&str; 8] = ["argv", "cwd", "resolved", "exitCode", "timedOut", "signal", "at", "run"];
fn exec_result_value(text: &str) -> Option<Json> {
    let value = json::parse(text)?;
    let Json::Obj(entries) = &value else { return None };
    if entries.len() != RESULT_KEYS.len() { return None; }
    let field = |key| value.get(key);
    let is_text = |key| matches!(field(key), Some(Json::Str(_)));
    let ok = matches!(field("argv"), Some(Json::Arr(list)) if !list.is_empty() && texts(list).is_some())
        && is_text("cwd") && is_text("resolved") && is_text("at") && is_text("run")
        && match field("exitCode") { Some(Json::Null) => true, Some(Json::Num(n)) => n.is_finite() && n.fract() == 0.0, _ => false }
        && matches!(field("timedOut"), Some(Json::Bool(_))) && matches!(field("signal"), Some(Json::Null | Json::Str(_)));
    if !ok { return None; }
    Some(object(RESULT_KEYS.into_iter().map(|key| (key, field(key).cloned().unwrap_or(Json::Null))).collect()))
}
impl Exec {
    pub fn json(&self) -> Json {
        object(vec![("argv", Json::Arr(self.argv.iter().cloned().map(Json::Str).collect())), ("cwd", Json::Str(self.cwd.clone())), ("why", Json::Str(self.why.clone()))])
    }
    pub fn quoted(&self) -> String { self.argv.iter().map(|a| js::shell_word(&a.lossy())).collect::<Vec<_>>().join(" ") }
    /// showExec
    pub fn show(&self) -> String { format!("{} (cwd {})", self.quoted(), js::shell_word(&self.cwd.lossy())) }
}

// ---------- parse ----------
/// The text after `prefix` where the rest of the line has no JavaScript line terminator, as `(.*)$` requires.
fn field<'a>(text: &'a str, prefix: &str) -> Option<&'a str> { text.strip_prefix(prefix).filter(|rest| js::dot_all(rest)) }
/// `- [ ] title`: (checked, title)
fn heading(text: &str) -> Option<(bool, &str)> {
    let (checked, rest) = match text.as_bytes().get(..6)? { b"- [ ] " => (false, &text[6..]), b"- [x] " | b"- [X] " => (true, &text[6..]), _ => return None };
    js::dot_all(rest).then_some((checked, rest))
}
fn event_line(text: &str) -> Option<Event> {
    let rest = text.strip_prefix("  - ")?;
    let at = rest.get(..16)?;
    let shape = at.bytes().zip(*b"0000-00-00 00:00").all(|(c, p)| if p == b'0' { c.is_ascii_digit() } else { c == p });
    let (who, what) = rest[16..].strip_prefix(' ')?.split_once(':')?;
    let what = what.strip_prefix(' ')?;
    (shape && !who.is_empty() && js::dot_all(what)).then(|| Event { at: at.into(), who: who.into(), what: what.into() })
}
pub fn parse(source: &str) -> Result<Model, Fail> {
    let raw: Vec<&str> = source.split('\n').collect();
    let lines: Vec<&str> = raw.iter().map(|l| l.strip_suffix('\r').unwrap_or(l)).collect();
    let boundary = lines.iter().position(|l| *l == "## Open")
        .or_else(|| lines.iter().position(|l| ["- [ ] ", "- [x] ", "- [X] "].iter().any(|p| l.starts_with(p)) || *l == "## Done"))
        .unwrap_or(lines.len());
    let mut preamble = raw[..boundary].join("\n");
    if boundary < lines.len() { preamble.push('\n'); }
    let mut model = Model { preamble, items: Vec::new() };
    let (mut section_done, mut open) = (false, false);
    for text in &lines[boundary..] {
        if *text == "## Open" || *text == "## Done" { section_done = *text == "## Done"; open = false; continue; }
        if let Some((checked, title)) = heading(text) {
            let title = if title.len() >= 4 && title.starts_with("~~") && title.ends_with("~~") { &title[2..title.len() - 2] } else { title };
            let mut item = Item::new(title.into());
            item.done = section_done || checked;
            item.checked_open = checked && !section_done;
            model.items.push(item);
            open = true;
            continue;
        }
        if !open || !text.starts_with(js::is_space) { continue; }
        let Some(item) = model.items.last_mut() else { continue };
        if let Some(v) = field(text, "  - project: ") { item.project = v.into(); }
        else if let Some((label, url)) = field(text, "  - link: [").and_then(|v| v.strip_suffix(')')).and_then(|v| v.rsplit_once("](")) { item.link = link_value(label, url)?; }
        else if let Some(v) = field(text, "  - sdlc: ") {
            let mut parts = v.splitn(3, " · ");
            let (slug, phase, rest) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next().unwrap_or(""));
            let (state, action) = rest.split_once(" — ").unwrap_or((rest, ""));
            item.sdlc = Some(Sdlc { slug: slug.into(), phase: phase.into(), state: state.into(), action: action.into() });
        }
        else if let Some(v) = field(text, "  - waiting: ") { item.waiting = v.into(); }
        else if let Some(v) = field(text, "  - others: ") { item.others = v.into(); }
        else if let Some(v) = field(text, "  - brief: ") { item.brief = v.into(); }
        else if let Some(v) = field(text, "  - repos: ") { item.repos = repo_list(v); }
        else if let Some(v) = field(text, "  - choices: ") { item.choices = choice_list(v); item.pick = None; }
        else if let Some(v) = field(text, "  - pick: ") { item.pick = pick_index(v, &item.choices); }
        else if let Some(v) = field(text, "  - suggest: ") { item.suggest = v.into(); }
        else if let Some(v) = field(text, "  - run: ") { item.run = v.into(); }
        else if let Some(v) = field(text, "  - exec: ").and_then(exec_value) { item.exec = Some(v); }
        else if let Some(v) = field(text, "  - execResult: ").and_then(exec_result_value) { item.exec_result = Some(v); }
        else if *text == "  - pin: yes" { item.pin = true; }
        else if let Some(event) = event_line(text) { item.events.push(event); }
        else { item.notes.push((*text).into()); }
    }
    identify(&mut model);
    Ok(model)
}
/// A file as Node reads utf8: invalid bytes become U+FFFD.
fn read_text(file: &str) -> std::io::Result<String> {
    let bytes = fs::read(file)?;
    Ok(match String::from_utf8(bytes) { Ok(text) => text, Err(error) => String::from_utf8_lossy(error.as_bytes()).into_owned() })
}
pub fn load(file: &str) -> Result<Model, Fail> {
    match read_text(file) {
        Ok(text) => parse(&text),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(Model { preamble: HEADER.into(), items: Vec::new() }),
        Err(error) => Err(Fail::io(&error, "open", file)),
    }
}

// ---------- render ----------
fn push_safe(out: &mut String, text: &str, json: bool) {
    for c in text.chars() {
        match c {
            '\r' if !json => out.push_str("\\r"),
            '\n' if !json => out.push_str("\\n"),
            '\u{85}' => out.push_str("\\u0085"),
            '\u{2028}' => out.push_str("\\u2028"),
            '\u{2029}' => out.push_str("\\u2029"),
            c => out.push(c),
        }
    }
}
fn safe_line(text: &str) -> String { let mut out = String::with_capacity(text.len()); push_safe(&mut out, text, false); out }

fn put(out: &mut String, name: &str, value: &str) {
    for part in ["\n  - ", name, ": ", value] { out.push_str(part); }
}
fn render_item(item: &Item) -> Result<String, Fail> {
    let mut out = if item.done { format!("- [x] ~~{}~~", item.title) } else { format!("- [ ] {}", item.title) };
    let some = |out: &mut String, name: &str, value: &str| if !value.is_empty() { put(out, name, value) };
    some(&mut out, "project", &item.project);
    if let Some((label, url)) = &item.link {
        if let Some((label, url)) = link_value(label, url)? { put(&mut out, "link", &format!("[{label}]({url})")); }
    }
    if let Some(s) = &item.sdlc {
        let mut text = s.slug.clone();
        if !s.phase.is_empty() { text.push_str(&format!(" · {}", s.phase)); }
        if !s.state.is_empty() {
            text.push_str(&format!(" · {}", s.state));
            if !s.action.is_empty() { text.push_str(&format!(" — {}", s.action)); }
        }
        put(&mut out, "sdlc", &text);
    }
    some(&mut out, "waiting", &item.waiting);
    some(&mut out, "others", &item.others);
    some(&mut out, "brief", &item.brief);
    some(&mut out, "repos", &item.repos.join(", "));
    some(&mut out, "choices", &item.choices.join(" | "));
    if let (false, Some(pick)) = (item.choices.is_empty(), item.pick) { put(&mut out, "pick", &pick.to_string()); }
    some(&mut out, "suggest", &item.suggest);
    some(&mut out, "run", &item.run);
    let one_line = |json: &Json| { let mut out = String::new(); push_safe(&mut out, &json.stringify(), true); out };
    if let Some(exec) = &item.exec { put(&mut out, "exec", &one_line(&exec.json())); }
    if let Some(result) = &item.exec_result { put(&mut out, "execResult", &one_line(result)); }
    if item.pin { put(&mut out, "pin", "yes"); }
    for e in &item.events {
        out.push_str(&format!("\n  - {} {}: ", e.at, e.who));
        push_safe(&mut out, &e.what, false);
    }
    for note in &item.notes { out.push('\n'); out.push_str(note); }
    Ok(out)
}
/// Every item's version, in order: the hash of its block, its place among identical blocks and how many there are.
pub fn versions(model: &Model) -> Result<Vec<String>, Fail> {
    let blocks = model.items.iter().map(render_item).collect::<Result<Vec<_>, _>>()?;
    let mut total: HashMap<&str, usize> = HashMap::new();
    for block in &blocks { *total.entry(block).or_default() += 1; }
    let mut seen: HashMap<&str, usize> = HashMap::new();
    Ok(blocks.iter().map(|block| {
        let at = seen.entry(block).or_default();
        let mut text = String::from("[");
        json::quote(block, &mut text);
        text.push_str(&format!(",{},{}]", *at, total[block.as_str()]));
        *at += 1;
        js::sha256(text.as_bytes())
    }).collect())
}
pub fn serialize(model: &Model) -> Result<String, Fail> {
    let group = |done: bool| -> Result<String, Fail> { Ok(model.items.iter().filter(|i| i.done == done).map(render_item).collect::<Result<Vec<_>, _>>()?.join("\n\n")) };
    let (open, done) = (group(false)?, group(true)?);
    Ok(format!("{}## Open\n\n{open}{}## Done\n\n{done}{}", model.preamble, if open.is_empty() { "" } else { "\n\n" }, if done.is_empty() { "" } else { "\n" }))
}

// ---------- history ----------
fn state_kind(e: &Event) -> &'static str {
    if e.who == "agent" {
        let what = e.what.as_str();
        if what.starts_with("waiting — ") { return "agent:waiting"; }
        if what == "brief cleared" || what.strip_prefix("brief ").is_some_and(|p| p.starts_with('/') || drive(p, "\\/") || p.starts_with("\\\\")) { return "agent:brief"; }
        if what.starts_with("suggest — ") || what == "suggest cleared" { return "agent:suggest"; }
        if what.starts_with("working — ") || what == "working cleared" { return "agent:working"; }
    }
    if e.who == "sdlc" {
        for (prefix, kind) in [("READY — ", "sdlc:READY"), ("NEEDS-HUMAN — ", "sdlc:NEEDS-HUMAN"), ("BLOCKED — ", "sdlc:BLOCKED"), ("DONE — ", "sdlc:DONE")] {
            if e.what.starts_with(prefix) { return kind; }
        }
    }
    ""
}
fn compact_events(model: &mut Model) -> Vec<(String, Vec<Event>)> {
    let mut history = Vec::new();
    for item in &mut model.items {
        let reply = item.events.iter().rposition(|e| e.who == "human" && e.what.starts_with("reply — "));
        let mut latest: HashMap<&str, usize> = HashMap::new();
        for (i, e) in item.events.iter().enumerate() { let kind = state_kind(e); if !kind.is_empty() { latest.insert(kind, i); } }
        let (mut kept, mut removed) = (Vec::with_capacity(item.events.len()), Vec::new());
        for (i, e) in std::mem::take(&mut item.events).into_iter().enumerate() {
            let kind = state_kind(&e);
            if e.who == "human" || reply.is_some_and(|r| i > r) || kind.is_empty() || latest[kind] == i { kept.push(e); } else { removed.push(e); }
        }
        item.events = kept;
        if !removed.is_empty() { history.push((item.id.clone(), removed)); }
        derive(item);
    }
    history
}
fn completed_overflow(model: &mut Model) -> Vec<Item> {
    let mut done = 0;
    let (kept, overflow) = std::mem::take(&mut model.items).into_iter().partition(|i| !i.done || { done += 1; done <= 30 });
    model.items = kept;
    overflow
}
fn append(file: &str, text: &str, head: &str) -> Result<(), Fail> {
    let io = |e: std::io::Error| Fail::io(&e, "open", file);
    let mut out = OpenOptions::new().append(true).create(true).open(file).map_err(io)?;
    let all = if out.metadata().map_err(io)?.len() == 0 { format!("{head}{text}") } else { text.into() };
    out.write_all(all.as_bytes()).map_err(io)
}
fn save_history(file: &str, history: &[(String, Vec<Event>)]) -> Result<(), Fail> {
    if history.is_empty() { return Ok(()); }
    let directory = join(&dirname(file), &["todo-history"]);
    fs::create_dir_all(&directory).map_err(|e| Fail::io(&e, "mkdir", &directory))?;
    for (id, events) in history {
        let text: String = events.iter().map(|e| format!("  - {} {}: {}\n", e.at, e.who, e.what)).collect();
        append(&join(&directory, &[&format!("{id}.log")]), &text, "")?;
    }
    Ok(())
}
pub fn event(item: &mut Item, who: &str, what: &str) {
    item.events.push(Event { at: stamp(), who: who.into(), what: safe_line(what) });
    derive(item);
}
/// Marks the item at `at` done and moves it to the head of the done ones.
pub fn finish(model: &mut Model, at: usize, who: &str, what: &str) {
    let mut item = model.items.remove(at);
    item.done = true;
    for text in [&mut item.waiting, &mut item.others, &mut item.suggest, &mut item.run] { text.clear(); }
    item.exec = None;
    event(&mut item, who, what);
    model.insert_before_done(item);
}
fn normalize(model: &mut Model) {
    for uid in model.items.iter().map(|i| i.uid).collect::<Vec<_>>() {
        let Some(at) = model.items.iter().position(|i| i.uid == uid) else { continue };
        if std::mem::take(&mut model.items[at].checked_open) { finish(model, at, "human", "done"); }
        if let Some(item) = model.items.iter_mut().find(|i| i.uid == uid) { if has_replies(item) { item.waiting.clear(); } }
    }
    identify(model);
}

// ---------- the lock shared with every Node process ----------
fn pause(ms: u64) { std::thread::sleep(Duration::from_millis(ms)); }
fn lost() -> Fail { Fail::kind(Kind::LockLost) }
fn lock_timeout(lock: &str) -> Fail { Fail::new(format!("timed out waiting for lock: {lock}")) }
/// Windows refuses for a moment while another process has the file open; a change already saved must not fail for that.
fn busy_retry(work: impl Fn() -> std::io::Result<()>) -> std::io::Result<()> {
    for attempt in 1..=5 {
        match work() { Err(e) if cfg!(windows) && matches!(js::errno(&e).0.as_str(), "EPERM" | "EBUSY") => pause(20 * attempt), done => return done }
    }
    work()
}
/// Removes a file; a missing one is fine.
fn unlink(file: &str) -> Result<(), Fail> {
    match busy_retry(|| fs::remove_file(file)) { Err(e) if e.kind() != ErrorKind::NotFound => Err(Fail::io(&e, "unlink", file)), _ => Ok(()) }
}
/// Replaces `file` whole, through a temporary file beside it.
pub fn atomic_write(file: &str, text: &str, owns: &dyn Fn() -> Result<bool, Fail>, mode: Option<u32>) -> Result<(), Fail> {
    let temp = join(&dirname(file), &[&format!(".{}.{}.{}.tmp", js::basename(file), std::process::id(), js::uuid().map_err(Fail::new)?)]);
    let result = (|| {
        write_new(&temp, text, mode)?;
        for attempt in 0.. {
            if !owns()? { return Err(lost()); }
            match fs::rename(&temp, file) {
                Ok(()) => break,
                Err(e) if attempt < 5 && matches!(js::errno(&e).0.as_str(), "EPERM" | "EBUSY") => pause(20 * (attempt + 1)),
                Err(e) => return Err(Fail::io(&e, "rename", &temp)),
            }
        }
        Ok(())
    })();
    let cleaned = unlink(&temp);
    if result.is_ok() { noted(cleaned); } else { cleaned?; }
    result
}
/// The session file: only the owner may read it, from the first byte on.
pub fn write_private(temp: &str, file: &str, text: &str) -> Result<(), Fail> {
    let result = write_new(temp, text, Some(0o600)).and_then(|()| fs::rename(temp, file).map_err(|e| Fail::io(&e, "rename", temp)));
    if result.is_err() { let _ = fs::remove_file(temp); }
    result
}
fn write_new(temp: &str, text: &str, mode: Option<u32>) -> Result<(), Fail> {
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    if let Some(mode) = mode { use std::os::unix::fs::OpenOptionsExt; options.mode(mode); }
    let mut out = options.open(temp).map_err(|e| Fail::io(&e, "open", temp))?;
    // Before the first byte. A file system without access lists (FAT) still gets the file, as Node leaves it.
    #[cfg(windows)]
    if mode == Some(0o600) { if let Err(e) = js::owner_only(Path::new(temp)) { eprintln!("to-do: {temp} is not limited to its owner: {e}"); } }
    out.write_all(text.as_bytes()).map_err(|e| Fail::io(&e, "write", temp))?;
    drop(out);
    #[cfg(unix)]
    if let Some(mode) = mode { use std::os::unix::fs::PermissionsExt; fs::set_permissions(temp, fs::Permissions::from_mode(mode)).map_err(|e| Fail::io(&e, "chmod", temp))?; }
    #[cfg(not(unix))]
    let _ = mode;
    Ok(())
}
fn is_uuid(text: &str) -> bool {
    let parts: Vec<&str> = text.split('-').collect();
    parts.len() == 5 && parts.iter().zip([8, 4, 4, 4, 12]).all(|(p, n)| p.len() == n && p.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
}
fn names(dir: &str) -> Result<Vec<String>, Fail> {
    let io = |e: std::io::Error| Fail::io(&e, "scandir", dir);
    fs::read_dir(dir).map_err(io)?.map(|entry| entry.map(|e| e.file_name().to_string_lossy().into_owned()).map_err(io)).collect()
}
fn age_ms(modified: std::io::Result<SystemTime>) -> i64 {
    match modified { Ok(at) => match SystemTime::now().duration_since(at) { Ok(d) => d.as_millis() as i64, Err(e) => -(e.duration().as_millis() as i64) }, Err(_) => 0 }
}
/// Temporary files a writer that died left behind, after an hour.
fn cleanup_temps(file: &str) -> Result<(), Fail> {
    let (dir, prefix) = (dirname(file), format!(".{}.", js::basename(file)));
    for name in names(&dir)? {
        let Some((pid, rest)) = name.strip_prefix(&prefix).and_then(|n| n.split_once('.')) else { continue };
        if pid.is_empty() || !pid.bytes().all(|b| b.is_ascii_digit()) || !rest.strip_suffix(".tmp").is_some_and(is_uuid) { continue; }
        let temp = join(&dir, &[&name]);
        match fs::symlink_metadata(&temp) {
            Ok(meta) => if meta.is_file() && age_ms(meta.modified()) > 3_600_000 { unlink(&temp)?; },
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(e) => return Err(Fail::io(&e, "lstat", &temp)),
        }
    }
    Ok(())
}
/// Moves a stale lock aside; one that turns out to be a successor's is put back without clobbering a newer owner.
fn remove_lock(lock: &str, observed: &[u8], moved: &str) -> Result<(), Fail> {
    match fs::rename(lock, moved) {
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(Fail::io(&e, "rename", lock)),
        Ok(()) => {}
    }
    let result = (|| {
        let io = |e: std::io::Error| Fail::io(&e, "open", moved);
        let same = fs::read(moved).map_err(io)? == observed;
        if !same || age_ms(fs::metadata(moved).map_err(io)?.modified()) <= 10_000 {
            match fs::hard_link(moved, lock) { Err(e) if e.kind() != ErrorKind::AlreadyExists => return Err(Fail::io(&e, "link", moved)), _ => {} }
        }
        Ok(())
    })();
    fs::remove_file(moved).map_err(|e| Fail::io(&e, "unlink", moved))?;
    result
}
/// A marker is an empty directory; an older kit left a file.
fn unmark(marker: &str) -> Result<(), Fail> { if busy_retry(|| fs::remove_dir(marker)).is_ok() { Ok(()) } else { unlink(marker) } }
/// Live processes' markers of a kind; a dead process's marker is removed and the lock it had moved aside restored.
fn markers(lock: &str, kind: &str) -> Result<usize, Fail> {
    let (dir, prefix) = (dirname(lock), format!("{}.{kind}-", js::basename(lock)));
    let mut active = 0;
    for name in names(&dir)? {
        let Some((pid, rest)) = name.strip_prefix(&prefix).and_then(|n| n.split_once('-')) else { continue };
        if pid.is_empty() || !pid.bytes().all(|b| b.is_ascii_digit()) || rest.is_empty() || !rest.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b) || b == b'-') { continue; }
        if pid.parse().is_ok_and(js::alive) { active += 1; continue; }
        let marker = join(&dir, &[&name]);
        let moved = format!("{marker}.moved");
        match fs::hard_link(&moved, lock) { Err(e) if !matches!(e.kind(), ErrorKind::NotFound | ErrorKind::AlreadyExists) => return Err(Fail::io(&e, "link", &moved)), _ => {} }
        unlink(&moved)?;
        unmark(&marker)?;
    }
    Ok(active)
}
/// A marker of this process; dropped without `release` (a panic) it is still removed.
struct Marker { path: String, held: bool }
impl Marker {
    fn release(mut self) -> Result<(), Fail> { self.held = false; unmark(&self.path) }
}
impl Drop for Marker { fn drop(&mut self) { if self.held { let _ = unmark(&self.path); } } }
fn mark(lock: &str, kind: &str) -> Result<Marker, Fail> {
    let path = format!("{lock}.{kind}-{}-{}", std::process::id(), js::uuid().map_err(Fail::new)?);
    fs::create_dir(&path).map_err(|e| Fail::io(&e, "mkdir", &path))?;
    Ok(Marker { path, held: true })
}
fn wait_markers(lock: &str, kind: &str) -> Result<(), Fail> {
    let deadline = Instant::now() + Duration::from_millis(2000);
    while markers(lock, kind)? > 0 {
        if Instant::now() >= deadline { return Err(lock_timeout(lock)); }
        pause(5);
    }
    Ok(())
}
fn owns_lock(lock: &str, owner: &str) -> Result<bool, Fail> {
    match fs::read(lock) { Ok(bytes) => Ok(bytes == owner.as_bytes()), Err(e) if e.kind() == ErrorKind::NotFound => Ok(false), Err(e) => Err(Fail::io(&e, "open", lock)) }
}
/// What goes wrong after a change is stored is said here and never becomes the change's answer: the person would send it again.
fn noted(result: Result<(), Fail>) { if let Err(error) = result { eprintln!("to-do: {}", error.message); } }
/// Runs `work` while no reclaimer can take the lock; None when the lock is no longer ours and need not be.
fn committing<T>(lock: &str, owner: &str, required: bool, work: &mut dyn FnMut() -> Result<T, Fail>) -> Result<Option<T>, Fail> {
    loop {
        wait_markers(lock, "reclaim")?;
        let marker = mark(lock, "commit")?;
        let result = (|| {
            // A reclaimer that arrived first wins; withdraw before waiting for it.
            if markers(lock, "reclaim")? > 0 { return Ok(None); }
            if !owns_lock(lock, owner)? { return if required { Err(lost()) } else { Ok(Some(None)) }; }
            work().map(|value| Some(Some(value)))
        })();
        let released = marker.release();
        match result {
            // The work is done: a marker that stays (it names this live process) is reported, not turned into a failure.
            Ok(Some(Some(value))) => { noted(released); return Ok(Some(value)); }
            Ok(Some(None)) => { released?; return Ok(None); }
            Ok(None) => released?,
            Err(error) => { noted(released); return Err(error); }
        }
    }
}
fn reclaim(lock: &str, observed: &[u8]) -> Result<(), Fail> {
    let marker = mark(lock, "reclaim")?;
    let moved = format!("{}.moved", marker.path);
    let result = wait_markers(lock, "commit").and_then(|()| remove_lock(lock, observed, &moved));
    marker.release()?;
    result
}
/// Windows refuses to open a lock file another process is still deleting: the lock is busy, not broken.
fn pending_delete(error: &std::io::Error) -> bool { cfg!(windows) && js::errno(error).0 == "EPERM" }

/// Refreshes the lock's time every second until dropped, so a long change is not taken for a dead one.
struct Heartbeat { stop: Option<mpsc::Sender<()>>, thread: Option<std::thread::JoinHandle<()>>, error: Arc<Mutex<Option<Fail>>> }
impl Heartbeat {
    fn start(lock: &str, file: &File) -> Result<Heartbeat, Fail> {
        let (stop, stopped) = mpsc::channel::<()>();
        let error = Arc::new(Mutex::new(None));
        let (slot, name) = (error.clone(), lock.to_string());
        let file = file.try_clone().map_err(|e| Fail::io(&e, "open", lock))?;
        let thread = std::thread::Builder::new().name("todo-lock".into()).stack_size(128 * 1024).spawn(move || {
            while stopped.recv_timeout(Duration::from_secs(1)) == Err(mpsc::RecvTimeoutError::Timeout) {
                let now = SystemTime::now();
                if let Err(e) = file.set_times(fs::FileTimes::new().set_accessed(now).set_modified(now)) { *slot.lock().unwrap_or_else(|e| e.into_inner()) = Some(Fail::io(&e, "futime", &name)); }
            }
        }).map_err(|e| Fail::new(format!("no heartbeat thread: {e}")))?;
        Ok(Heartbeat { stop: Some(stop), thread: Some(thread), error })
    }
    fn failed(&self) -> Result<(), Fail> { match self.error.lock().unwrap_or_else(|e| e.into_inner()).take() { Some(error) => Err(error), None => Ok(()) } }
}
impl Drop for Heartbeat {
    fn drop(&mut self) { self.stop.take(); if let Some(thread) = self.thread.take() { let _ = thread.join(); } }
}

/// A list as one server writes it; a closed server may not start another write.
#[derive(Clone)]
pub struct List { pub file: String, closed: Arc<std::sync::atomic::AtomicBool> }
impl List {
    pub fn new(file: &str) -> List { List { file: file.into(), closed: Arc::default() } }
    pub fn close(&self) { self.closed.store(true, Ordering::SeqCst); }
    pub fn is_closed(&self) -> bool { self.closed.load(Ordering::SeqCst) }
}

/// Changes being written right now, so a quit can let them finish.
pub static WRITING: AtomicUsize = AtomicUsize::new(0);
struct Writing;
impl Writing { fn begin() -> Writing { WRITING.fetch_add(1, Ordering::SeqCst); Writing } }
impl Drop for Writing { fn drop(&mut self) { WRITING.fetch_sub(1, Ordering::SeqCst); } }

/// Creates the lock file, taking over one whose owner stopped beating more than 10 s ago.
fn take_lock(lock: &str, deadline: Instant) -> Result<File, Fail> {
    loop {
        wait_markers(lock, "reclaim")?;
        let error = match OpenOptions::new().write(true).create_new(true).open(lock) { Ok(file) => return Ok(file), Err(error) => error };
        if error.kind() != ErrorKind::AlreadyExists && !pending_delete(&error) { return Err(Fail::io(&error, "open", lock)); }
        match fs::read(lock).and_then(|observed| Ok((observed, fs::metadata(lock)?))) {
            Ok((observed, meta)) => if age_ms(meta.modified()) > 10_000 {
                match reclaim(lock, &observed) {
                    Ok(()) => continue,
                    Err(e) if e.message.starts_with("ENOENT") => continue,
                    Err(e) if cfg!(windows) && e.message.starts_with("EPERM") => {}
                    Err(e) => return Err(e),
                }
            },
            Err(e) if e.kind() == ErrorKind::NotFound => continue,
            Err(e) if pending_delete(&e) => {}
            Err(e) => return Err(Fail::io(&e, "open", lock)),
        }
        if Instant::now() >= deadline { return Err(lock_timeout(lock)); }
        pause(20);
    }
}
/// Reads, changes and replaces the list under the lock. `change` runs again when another process took the lock over.
pub fn mutate<T>(list: &List, change: &mut dyn FnMut(&mut Model) -> Result<T, Fail>) -> Result<T, Fail> {
    let _writing = Writing::begin();
    // Counted first, then checked: close() sets the flag, then waits for the count.
    if list.closed.load(Ordering::SeqCst) { return Fail::at(503, "the to-do server is closing"); }
    let file = list.file.as_str();
    let dir = dirname(file);
    fs::create_dir_all(&dir).map_err(|e| Fail::io(&e, "mkdir", &dir))?;
    let (lock, deadline) = (format!("{file}.lock"), Instant::now() + Duration::from_millis(2000));
    loop {
        let mut handle = take_lock(&lock, deadline)?;
        let owner = js::uuid();
        let heartbeat = Heartbeat::start(&lock, &handle);
        let name = owner.as_deref().unwrap_or("");
        // A panic inside must not leave the lock behind while this process lives.
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<T, Fail> {
            let owner = owner.as_ref().map_err(|e| Fail::new(e.clone()))?;
            let heartbeat = match &heartbeat { Ok(beat) => beat, Err(error) => return Err(Fail::new(error.message.clone())) };
            handle.write_all(owner.as_bytes()).map_err(|e| Fail::io(&e, "write", &lock))?;
            wait_markers(&lock, "reclaim")?;
            if !owns_lock(&lock, owner)? { return Err(lost()); }
            committing(&lock, owner, true, &mut || cleanup_temps(file))?;
            let mut model = load(file)?;
            normalize(&mut model);
            let before: HashMap<u64, String> = model.items.iter().map(|i| (i.uid, i.id.clone())).collect();
            let mut value = Some(change(&mut model)?);
            heartbeat.failed()?;
            let saved = committing(&lock, owner, true, &mut || {
                normalize(&mut model);
                let history = compact_events(&mut model);
                save_history(file, &history)?;
                let overflow = completed_overflow(&mut model);
                if !overflow.is_empty() {
                    let blocks = overflow.iter().map(render_item).collect::<Result<Vec<_>, _>>()?;
                    append(&join(&dir, &["todo-archive.md"]), &format!("{}\n\n", blocks.join("\n\n")), "# To-do archive\n\n")?;
                }
                atomic_write(file, &serialize(&model)?, &|| owns_lock(&lock, owner), None)?;
                noted(follow_ids(file, &before, &model));
                Ok(value.take())
            })?;
            saved.flatten().ok_or_else(lost)
        }));
        // An unwritten owner (an early failure) is an empty file, as Node would leave it: only its maker removes it.
        let written = owns_lock(&lock, name).unwrap_or(false);
        let released = if written { committing(&lock, name, false, &mut || busy_retry(|| fs::remove_file(&lock)).map_err(|e| Fail::io(&e, "unlink", &lock))).map(|_| ()) } else { Ok(()) };
        drop(heartbeat);
        drop(handle);
        match result {
            Err(panic) => std::panic::resume_unwind(panic),
            Ok(result) => {
                if result.is_ok() { noted(released); } else { released?; }
                match result { Err(error) if error.kind == Kind::LockLost => continue, other => return other }
            }
        }
    }
}

// ---------- operations ----------
pub fn add(list: &List, text: &str) -> Result<(), Fail> {
    let parsed = parse_text(text)?;
    let project = if is_relative_project(&parsed.project) { js::resolve(&parsed.project) } else { parsed.project };
    mutate(list, &mut |model| {
        if parsed.title.is_empty() { return Err(Fail::new("title or --slug required")); }
        let mut item = Item::new(parsed.title.clone());
        item.project = project.clone();
        item.link = parsed.link.clone();
        event(&mut item, "human", "added");
        model.insert_before_done(item);
        identify(model);
        Ok(())
    })
}
/// Changes the item shown at `version`; anything else about it is a conflict. `change` gets its place in the list.
pub fn update<T>(list: &List, id: Option<&str>, version: Option<&str>, change: &mut dyn FnMut(&mut Model, usize) -> Result<T, Fail>) -> Result<T, Fail> {
    mutate(list, &mut |model| {
        let at = id.and_then(|id| model.by_id(id));
        let shown = match at { Some(at) if version.is_some() => versions(model)?.get(at).map(String::as_str) == version, _ => false };
        let Some(at) = at.filter(|_| shown) else { return Fail::at(409, CHANGED) };
        let value = change(model, at)?;
        identify(model);
        Ok(value)
    })
}
pub fn edit(list: &List, id: Option<&str>, version: Option<&str>, title: &str) -> Result<(), Fail> {
    update(list, id, version, &mut |model, at| { let item = &mut model.items[at]; item.title = line(title)?; event(item, "human", "edited"); Ok(()) })
}
pub fn move_by(list: &List, id: Option<&str>, version: Option<&str>, delta: i64) -> Result<(), Fail> {
    update(list, id, version, &mut |model, at| {
        let group: Vec<usize> = (0..model.items.len()).filter(|i| model.items[*i].done == model.items[at].done).collect();
        let from = group.iter().position(|i| *i == at).unwrap_or(0) as i64;
        let target = group[(from + delta).clamp(0, group.len() as i64 - 1) as usize];
        let item = model.items.remove(at);
        model.items.insert(target, item);
        Ok(())
    })
}
pub fn remove(list: &List, id: Option<&str>, version: Option<&str>) -> Result<(), Fail> {
    update(list, id, version, &mut |model, at| { model.items.remove(at); Ok(()) })
}
pub fn done(list: &List, id: Option<&str>, version: Option<&str>) -> Result<(), Fail> {
    update(list, id, version, &mut |model, at| { finish(model, at, "human", "done"); Ok(()) })
}
pub fn undone(list: &List, id: Option<&str>, version: Option<&str>) -> Result<(), Fail> {
    update(list, id, version, &mut |model, at| {
        let mut item = model.items.remove(at);
        item.done = false;
        item.events.push(Event { at: stamp(), who: "human".into(), what: "undone".into() });
        model.insert_before_done(item);
        Ok(())
    })
}
pub fn reply(list: &List, id: Option<&str>, version: Option<&str>, words: &str) -> Result<(), Fail> {
    update(list, id, version, &mut |model, at| {
        let item = &mut model.items[at];
        for text in [&mut item.waiting, &mut item.others, &mut item.suggest, &mut item.run] { text.clear(); }
        item.exec = None;
        event(item, "human", &format!("reply — {}", line(words)?));
        Ok(())
    })
}
/// The item a fix was requested for: its id and project.
pub fn request_fix(list: &List, id: Option<&str>, version: Option<&str>) -> Result<(String, String), Fail> {
    update(list, id, version, &mut |model, at| {
        let item = &mut model.items[at];
        if item.done || item.status != Status::Blocked || item.relative { return Fail::at(409, "only a blocked sdlc item can be fixed by an agent"); }
        event(item, "human", FIX_REQUEST);
        Ok((item.id.clone(), item.project.clone()))
    })
}

// ---------- status sync ----------
/// One item's status as sdlc.sh gave it, and what the list said when it was asked.
pub struct Reading { pub id: String, pub project: String, pub previous: Sdlc, pub current: Sdlc }
fn in_scope(item: &Item, only: &str) -> bool { !item.done && !item.project.is_empty() && item.sdlc.is_some() && (only.is_empty() || item.id == only) }
pub fn scoped(file: &str, only: &str) -> Result<Vec<Item>, Fail> { Ok(load(file)?.items.into_iter().filter(|i| in_scope(i, only)).collect()) }
pub fn apply_readings(list: &List, readings: &[Reading], only: &str) -> Result<(), Fail> {
    mutate(list, &mut |model| {
        // Status calls run unlocked; retry if any current slug lacks the same preimage.
        let covered = |item: &Item| readings.iter().any(|r| r.id == item.id && r.project == item.project && Some(&r.previous) == item.sdlc.as_ref());
        if model.items.iter().any(|item| in_scope(item, only) && !covered(item)) { return Err(Fail::kind(Kind::SyncChanged)); }
        for r in readings {
            let Some(at) = model.items.iter().position(|i| i.id == r.id && i.project == r.project && !i.done) else { continue };
            let item = &mut model.items[at];
            // A concurrent edit/start/sync wins over a status read of an older item.
            if item.sdlc.as_ref() != Some(&r.previous) { continue; }
            item.sdlc = Some(r.current.clone());
            if r.current.state == "DONE" { finish(model, at, "sdlc", &format!("DONE — {}", r.current.action)); continue; }
            let turned = matches!(r.current.state.as_str(), "NEEDS-HUMAN" | "BLOCKED") && r.previous.state != r.current.state;
            if turned || r.previous.action != r.current.action { event(item, "sdlc", &format!("{} — {}", r.current.state, r.current.action)); }
            if has_replies(item) { item.waiting.clear(); }
            derive(item);
        }
        identify(model);
        Ok(())
    })
}

// ---------- working markers ----------
pub struct Mark { pub what: Text, pub since: Text, pub beat: Text, pub at: i64 }
/// The live markers, and whether some marker's time could not be read: it is left out, the others are not.
#[derive(Default)]
pub struct Working { pub live: Vec<(Text, Mark)>, pub unread: bool }
pub fn working_path(file: &str) -> String { join(&dirname(file), &["todo-working.json"]) }
pub fn working_ttl() -> i64 {
    // Number(env): only plain decimals are used; anything else keeps the default.
    let seconds = std::env::var("SDLC_TODO_WORKING_TTL").ok().and_then(|v| js::trim(&v).parse::<f64>().ok()).filter(|s| *s > 0.0 && s.is_finite());
    seconds.map_or(180_000, |s| (s * 1000.0) as i64)
}
/// Live markers only; a missing or unreadable file is no marker.
pub fn read_working(file: &str, now: i64) -> Working {
    let mut out = Working::default();
    for (id, mark) in stored_marks(file) {
        let (Some(Json::Str(since)), Some(Json::Str(beat))) = (mark.get("since"), mark.get("beat")) else { continue };
        let at = match helper::date(&beat.lossy()) { Ok(Some(at)) => at, Ok(None) => continue, Err(_) => { out.unread = true; continue; } };
        if !live_at(at, now) { continue; }
        out.live.push((id, Mark { what: what_of(&mark), since: since.clone(), beat: beat.clone(), at }));
    }
    out
}
fn stored_marks(file: &str) -> Vec<(Text, Json)> {
    match read_text(&working_path(file)).ok().and_then(|text| json::parse(&text)) { Some(Json::Obj(marks)) => marks, _ => Vec::new() }
}
fn live_at(at: i64, now: i64) -> bool { now - at < working_ttl() && at <= now + 5000 }
fn what_of(mark: &Json) -> Text { match mark.get("what") { Some(Json::Str(what)) => what.clone(), _ => Text::default() } }
impl Mark {
    pub fn json(&self) -> Json { object(vec![("what", Json::Str(self.what.clone())), ("since", Json::Str(self.since.clone())), ("beat", Json::Str(self.beat.clone()))]) }
}
/// A change of slug or title changes the id: the live marker moves with the item.
fn follow_ids(file: &str, before: &HashMap<u64, String>, model: &Model) -> Result<(), Fail> {
    let moved: Vec<(Text, Text)> = model.items.iter().filter_map(|i| before.get(&i.uid).filter(|old| **old != i.id).map(|old| (old.as_str().into(), i.id.as_str().into()))).collect();
    if moved.is_empty() { return Ok(()); }
    // Under the list's lock no Node helper is asked: a time only JavaScript reads keeps its marker, which moves like any other.
    let now = js::now_ms();
    let mut marks: Vec<(Text, Json)> = stored_marks(file).into_iter().filter_map(|(id, mark)| {
        let (Some(Json::Str(since)), Some(Json::Str(beat))) = (mark.get("since"), mark.get("beat")) else { return None };
        if js::parse_iso(&beat.lossy()).is_some_and(|at| !live_at(at, now)) { return None; }
        let kept = object(vec![("what", Json::Str(what_of(&mark))), ("since", Json::Str(since.clone())), ("beat", Json::Str(beat.clone()))]);
        Some((id, kept))
    }).collect();
    let find = |marks: &[(Text, Json)], id: &Text| marks.iter().position(|(k, _)| k == id);
    if !moved.iter().any(|(old, new)| find(&marks, old).is_some() || find(&marks, new).is_some()) { return Ok(()); }
    let carried: Vec<(Text, Option<Json>)> = moved.iter().map(|(old, new)| (new.clone(), find(&marks, old).map(|i| marks[i].1.clone()))).collect();
    for (old, _) in &moved { if let Some(i) = find(&marks, old) { marks.remove(i); } }
    for (new, mark) in carried {
        match (find(&marks, &new), mark) {
            (Some(i), Some(mark)) => marks[i].1 = mark,
            (None, Some(mark)) => marks.push((new, mark)),
            (Some(i), None) => { marks.remove(i); }
            (None, None) => {}
        }
    }
    json::order(&mut marks);
    atomic_write(&working_path(file), &format!("{}\n", Json::Obj(marks).stringify()), &|| Ok(true), Some(0o600))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(not(windows))]
    use std::path::Path;

    fn folder(name: &str) -> (std::path::PathBuf, String) {
        let dir = std::env::temp_dir().join(format!("sdlc-todo-{name}-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let file = dir.join("todo.md").to_string_lossy().into_owned();
        (dir, file)
    }
    fn left_behind(dir: &Path) -> Vec<String> { names(&dir.to_string_lossy()).unwrap().into_iter().filter(|n| n.contains(".lock") || n.ends_with(".tmp")).collect() }

    #[test]
    fn many_writers_and_open_readers_lose_and_tear_nothing() {
        let (dir, file) = folder("writers");
        let stop = std::sync::atomic::AtomicBool::new(false);
        std::thread::scope(|scope| {
            // A reader that keeps the file open makes the replacing rename fail on Windows; it must be retried.
            scope.spawn(|| while !stop.load(Ordering::SeqCst) {
                if let Ok(open) = File::open(&file) {
                    pause(3);
                    let text = std::io::read_to_string(open).unwrap();
                    assert!(text.starts_with("# To-do\n") && text.ends_with('\n') && text.contains("## Done\n"));
                }
                pause(1);
            });
            let writers: Vec<_> = (0..4).map(|w| { let file = &file; scope.spawn(move || for i in 0..40 {
                let title = format!("item-{w}-{i}");
                while let Err(error) = add(&List::new(file), &title) {
                    if error.message.starts_with("timed out waiting for lock") { continue; }
                    // Windows may report a sharing error after the change was saved.
                    assert!(cfg!(windows), "{}", error.message);
                    if load(file).is_ok_and(|m| m.items.iter().any(|i| i.title == title)) { break; }
                }
            }) }).collect();
            let results: Vec<_> = writers.into_iter().map(|w| w.join()).collect();
            stop.store(true, Ordering::SeqCst);
            assert!(results.into_iter().all(|r| r.is_ok()));
        });
        let mut titles: Vec<String> = load(&file).unwrap().items.into_iter().map(|i| i.title).collect();
        titles.sort();
        titles.dedup();
        assert_eq!((titles.len(), load(&file).unwrap().items.len()), (160, 160));
        assert!(left_behind(&dir).is_empty(), "{:?}", left_behind(&dir));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_stale_lock_is_taken_over_and_a_live_one_is_not() {
        let (dir, file) = folder("stale");
        let lock = format!("{file}.lock");
        fs::write(&lock, "dead owner").unwrap();
        fs::create_dir(format!("{lock}.commit-2147483644-0aa0aa00")).unwrap();
        File::options().write(true).open(&lock).unwrap().set_modified(SystemTime::now() - Duration::from_secs(20)).unwrap();
        add(&List::new(&file), "after a dead owner").unwrap();
        fs::write(&lock, "live owner").unwrap();
        assert_eq!(add(&List::new(&file), "refused").unwrap_err().message, format!("timed out waiting for lock: {lock}"));
        fs::remove_file(&lock).unwrap();
        assert_eq!(load(&file).unwrap().items.len(), 1);
        assert!(left_behind(&dir).is_empty(), "{:?}", left_behind(&dir));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_marker_with_an_unreadable_time_holds_no_other_back() {
        // No helper is configured for this list's times: one is ISO, one is not.
        let (dir, file) = folder("markers");
        let list = List::new(&file);
        fs::write(&file, "## Open\n\n- [ ] a\n\n- [ ] b\n\n- [ ] c\n").unwrap();
        let id = |title: &str| { let m = load(&file).unwrap(); let i = m.items.iter().find(|i| i.title == title).unwrap(); i.id.clone() };
        let now = js::iso(js::now_ms());
        fs::write(working_path(&file), format!("{{\"{}\":{{\"what\":\"w\",\"since\":\"{now}\",\"beat\":\"{now}\"}},\"{}\":{{\"what\":\"odd\",\"since\":\"{now}\",\"beat\":\"Wed Nov 25 2026\"}}}}\n", id("a"), id("b"))).unwrap();
        for (title, next) in [("a", "a2"), ("b", "b2")] {
            let model = load(&file).unwrap();
            let at = model.items.iter().position(|i| i.title == title).unwrap();
            edit(&list, Some(&model.items[at].id), Some(&versions(&model).unwrap()[at]), next).unwrap();
        }
        let marks = stored_marks(&file);
        let what = |title: &str| marks.iter().find(|(k, _)| *k == id(title).as_str().into()).map(|(_, m)| what_of(m).lossy());
        assert_eq!((what("a2").as_deref(), what("b2").as_deref(), marks.len()), (Some("w"), Some("odd"), 2));
        fs::remove_dir_all(dir).unwrap();
    }

    // Only macOS lets a test make a rename over a readable file fail for its own user.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_stored_change_succeeds_when_its_marker_cannot_follow() {
        let (dir, file) = folder("stored");
        let list = List::new(&file);
        add(&list, "a").unwrap();
        let (model, now, working) = (load(&file).unwrap(), js::iso(js::now_ms()), working_path(&file));
        fs::write(&working, format!("{{\"{}\":{{\"what\":\"w\",\"since\":\"{now}\",\"beat\":\"{now}\"}}}}", model.items[0].id)).unwrap();
        let flag = |flag: &str| assert!(std::process::Command::new("/usr/bin/chflags").args([flag, &working]).status().unwrap().success());
        flag("uchg");
        let before: HashMap<u64, String> = model.items.iter().map(|i| (i.uid, i.id.clone())).collect();
        let mut renamed = load(&file).unwrap();
        (renamed.items[0].uid, renamed.items[0].id) = (model.items[0].uid, "other".into());
        let refused = follow_ids(&file, &before, &renamed).is_err();
        let edited = edit(&list, Some(&model.items[0].id), Some(&versions(&model).unwrap()[0]), "b");
        flag("nouchg");
        assert!(refused && edited.is_ok(), "{edited:?}");
        assert_eq!(load(&file).unwrap().items[0].title, "b");
        assert!(left_behind(&dir).is_empty(), "{:?}", left_behind(&dir));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_error_and_a_panic_release_the_lock_and_change_nothing() {
        let (dir, file) = folder("panic");
        add(&List::new(&file), "kept").unwrap();
        let before = fs::read_to_string(&file).unwrap();
        assert!(mutate(&List::new(&file), &mut |model| { model.items.clear(); Err::<(), _>(Fail::new("no")) }).is_err());
        let panicked = std::panic::catch_unwind(|| mutate(&List::new(&file), &mut |model| -> Result<(), Fail> { model.items.clear(); panic!("on purpose") }));
        assert!(panicked.is_err());
        assert_eq!(fs::read_to_string(&file).unwrap(), before);
        assert!(left_behind(&dir).is_empty(), "{:?}", left_behind(&dir));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_session_file_is_its_owners_alone() {
        let (dir, file) = folder("private");
        write_private(&format!("{file}.tmp"), &file, "secret\n").unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap(), "secret\n");
        #[cfg(unix)]
        { use std::os::unix::fs::PermissionsExt; assert_eq!(fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600); }
        #[cfg(windows)]
        {
            let shown = std::process::Command::new("icacls").arg(&file).output().unwrap();
            let shown = String::from_utf8_lossy(&shown.stdout).into_owned();
            assert_eq!(shown.matches("(F)").count(), 1, "one full-control entry: {shown}");
            assert!(!shown.contains("(I)"), "nothing inherited: {shown}");
        }
        fs::remove_dir_all(dir).unwrap();
    }
}
