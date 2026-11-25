//! The to-do web server as a library: the routes, checks and answers of todo/web.mjs, so a shell runs no Node
//! server. The CLI and TUI keep todo.mjs; both write the same files under the same lock (core.rs). A shell calls
//! `find_or_start`, talks HTTP to 127.0.0.1 with the token, and calls `Handle::close` before it exits.
mod board_run;
#[doc(hidden)]
pub mod core;
mod helper;
mod http;
mod js;
#[doc(hidden)]
pub mod json;
mod run;
mod sync;

use self::core::{Fail, Item, Model, Status};
use json::{object, Json};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant, SystemTime};

const LANGUAGES: [&str; 2] = ["en", "ko"];
const KEEPALIVE: Duration = Duration::from_secs(15);
/// Frames a stream may fall behind by before it is dropped; its page reconnects and gets the whole list.
const BACKLOG: usize = 64;
const CONNECTIONS: usize = 256;

pub struct Options {
    /// The to-do list, its optional feed and the session file ('' for none).
    pub file: String,
    pub feed: String,
    pub session: PathBuf,
    /// Where sdlc.sh is, and the todo folder the page is served from.
    pub kit: String,
    pub pages: PathBuf,
    /// Answers the few JavaScript-only questions (helper.rs).
    pub node: String,
    pub lang: String,
    /// Syncs every item before the first answer instead of in the background.
    pub sync_first: bool,
    pub run_timeout: u64,
    pub kill_after: u64,
    pub finish_retry: u64,
    pub search_path: Option<String>,
    pub can_exec: bool,
    /// The process named in the session file and in run records.
    pub pid: u32,
}

impl Options {
    /// The server `todo.mjs serve` would be: the list from the environment, pages and scripts from the kit.
    pub fn for_kit(kit: &Path, session: &Path, node: &str, lang: &str) -> Options {
        let env = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty());
        let file = env("SDLC_TODO").unwrap_or_else(|| js::join(&js::home(), &[".sdlc", "todo.md"]));
        // Node resolves the kit through links, and its path is part of the error words in the list.
        let kit = plain(std::fs::canonicalize(kit).unwrap_or_else(|_| kit.into()));
        Options {
            feed: env("SDLC_TODO_FEED").unwrap_or_else(|| js::join(&js::dirname(&file), &["todo-feed.json"])),
            file, session: session.into(), pages: Path::new(&kit).join("todo"), kit, node: node.into(),
            lang: if LANGUAGES.contains(&lang) { lang.into() } else { LANGUAGES[0].into() },
            sync_first: false, run_timeout: 300_000, kill_after: 5000, finish_retry: 30_000, search_path: None, can_exec: cfg!(unix), pid: std::process::id(),
        }
    }
}
/// A canonical path without Windows' \\?\ prefix.
fn plain(path: PathBuf) -> String {
    let text = path.to_string_lossy().into_owned();
    if let Some(share) = text.strip_prefix(r"\\?\UNC\") { return format!(r"\\{share}"); }
    text.strip_prefix(r"\\?\").map(str::to_string).unwrap_or(text)
}
/// A console window must not flash up for a child on Windows.
fn no_window(command: &mut std::process::Command) {
    #[cfg(windows)]
    { use std::os::windows::process::CommandExt; command.creation_flags(0x0800_0000); }
    #[cfg(not(windows))]
    let _ = command;
}
static SESSION_ENV: Mutex<Option<PathBuf>> = Mutex::new(None);
/// Children see the session file the server was started with, as those of `todo.mjs serve` do.
fn session_env() -> Option<PathBuf> { locked(&SESSION_ENV).clone() }
fn child_env(command: &mut std::process::Command) {
    if let Some(session) = session_env() { command.env("SDLC_TODO_SESSION", session); }
}
fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> { mutex.lock().unwrap_or_else(|e| e.into_inner()) }

/// The feed's JSON text and why it could not be read.
#[derive(Clone)]
struct Feed { json: String, error: &'static str }
fn read_feed(file: &str) -> Feed {
    let none = |error| Feed { json: "null".into(), error };
    let bytes = match std::fs::read(file) {
        Ok(bytes) => bytes,
        Err(error) => return none(if matches!(js::errno(&error).0.as_str(), "ENOENT" | "ENOTDIR") { "" } else { "feed not readable" }),
    };
    if bytes.len() > 1024 * 1024 { return none("feed too large"); }
    match json::parse(&String::from_utf8_lossy(&bytes)) {
        Some(feed @ Json::Obj(_)) => Feed { json: feed.stringify(), error: "" },
        Some(_) => none("feed is not a JSON object"),
        None => none("feed is not valid JSON"),
    }
}

/// One sync that every reader waiting for it shares.
type Sync = Arc<(Mutex<Option<Result<(), String>>>, Condvar)>;

struct Server {
    options: Options,
    port: u16,
    token: String,
    /// Open event streams. Held while a frame is built and queued, so frames arrive in the order they were built.
    clients: Mutex<Vec<mpsc::SyncSender<Arc<str>>>>,
    feed: Mutex<Feed>,
    syncing: Mutex<Option<Sync>>,
    search_path: OnceLock<String>,
    /// This server's nonce: it knows its own runs, whatever process id they carry.
    run_server: String,
    closing: AtomicBool,
    connections: AtomicUsize,
}

/// Where a server answers on 127.0.0.1 and the token it asks for.
#[derive(Clone, PartialEq, Eq)]
pub struct Session { pub port: u16, pub token: String }

/// A running server; close it before the process exits.
pub struct Handle { server: Arc<Server> }

impl Handle {
    pub fn session(&self) -> Session { Session { port: self.server.port, token: self.server.token.clone() } }
    /// Stops answering, removes the session file when it is ours, and lets a write in progress finish.
    pub fn close(&self) {
        if self.server.closing.swap(true, Ordering::SeqCst) { return; }
        remove_session(&self.server.options.session, &self.server.token);
        locked(&self.server.clients).clear();
        // Wakes the accept loop so it sees that it is closing.
        let _ = TcpStream::connect(("127.0.0.1", self.server.port));
        let_writes_finish();
    }
}

// ---------- session file ----------
fn read_session(file: &Path) -> Option<Session> {
    let value = json::parse(&std::fs::read_to_string(file).ok()?)?;
    let Some(Json::Num(port)) = value.get("port") else { return None };
    let token = value.get("token")?.text().filter(|t| t.len() == 32 && t.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))?;
    (port.fract() == 0.0 && (1.0..65536.0).contains(port)).then_some(Session { port: *port as u16, token })
}
/// The server a session file names, when it answers.
pub fn live(file: &Path) -> Option<Session> {
    use std::io::{Read, Write};
    let session = read_session(file)?;
    let limit = Some(Duration::from_secs(2));
    let mut stream = TcpStream::connect_timeout(&([127, 0, 0, 1], session.port).into(), Duration::from_secs(2)).ok()?;
    stream.set_read_timeout(limit).ok()?;
    stream.set_write_timeout(limit).ok()?;
    stream.write_all(format!("GET /api/live HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nX-Todo-Token: {}\r\nConnection: close\r\n\r\n", session.port, session.token).as_bytes()).ok()?;
    let mut status = [0; 12];
    stream.read_exact(&mut status).ok()?;
    (&status == b"HTTP/1.1 200").then_some(session)
}
/// The running server of the session file, or one started here with its handle.
pub fn find_or_start(options: Options) -> Result<(Session, Option<Handle>), String> {
    if let Some(session) = live(&options.session) { return Ok((session, None)); }
    let handle = start(options)?;
    Ok((handle.session(), Some(handle)))
}
fn remove_session(file: &Path, token: &str) {
    if !file.as_os_str().is_empty() && read_session(file).is_some_and(|s| s.token == token) { let _ = std::fs::remove_file(file); }
}
fn write_session(file: &Path, port: u16, token: &str, pid: u32) -> Result<(), Fail> {
    let name = file.to_string_lossy().into_owned();
    let dir = js::dirname(&name);
    std::fs::create_dir_all(&dir).map_err(|e| Fail::io(&e, "mkdir", &dir))?;
    let temp = format!("{name}.{}.tmp", std::process::id());
    core::write_private(&temp, &name, &format!("{{\"port\":{port},\"token\":\"{token}\",\"pid\":{pid}}}\n"))
}
/// The sessions to remove when the process ends by itself (exit() on quit or logout).
static OPEN: Mutex<Vec<(PathBuf, String)>> = Mutex::new(Vec::new());
#[cfg(unix)]
extern "C" fn at_exit() { remove_open_sessions(); }
#[cfg(unix)]
fn remove_open_sessions() { if let Ok(open) = OPEN.try_lock() { for (file, token) in open.iter() { remove_session(file, token); } } }
/// Waits a moment for changes being written: a process that ends mid-write leaves a lock others wait 10 s for.
fn let_writes_finish() {
    let until = Instant::now() + Duration::from_secs(2);
    while core::WRITING.load(Ordering::SeqCst) > 0 && Instant::now() < until { std::thread::sleep(Duration::from_millis(10)); }
}
#[cfg(unix)]
static SIGNAL_PIPE: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);
#[cfg(unix)]
extern "C" fn on_signal(signal: libc::c_int) {
    let byte = signal as u8;
    // SAFETY: write is async-signal-safe; one byte from the stack.
    unsafe { libc::write(SIGNAL_PIPE.load(Ordering::SeqCst), (&raw const byte).cast(), 1); }
}
/// SIGTERM and SIGINT end the process as before, after the session file is removed.
#[cfg(unix)]
fn clean_up_on_signals() -> Result<(), String> {
    let mut ends = [0; 2];
    // SAFETY: a pipe for this process; the handler only writes to it.
    unsafe {
        if libc::pipe(ends.as_mut_ptr()) != 0 { return Err(std::io::Error::last_os_error().to_string()); }
        for end in ends { libc::fcntl(end, libc::F_SETFD, libc::FD_CLOEXEC); }
        SIGNAL_PIPE.store(ends[1], Ordering::SeqCst);
        for signal in [libc::SIGTERM, libc::SIGINT] { libc::signal(signal, on_signal as *const () as libc::sighandler_t); }
    }
    spawn("todo-signal", move || {
        let mut byte = 0u8;
        // SAFETY: reads one byte; then the default action ends the process.
        while unsafe { libc::read(ends[0], (&raw mut byte).cast(), 1) } != 1 {}
        remove_open_sessions();
        let_writes_finish();
        unsafe { libc::signal(byte as i32, libc::SIG_DFL); libc::kill(libc::getpid(), byte as i32); }
    })
}

pub fn configure_helper(options: &Options) { helper::configure(&options.node, &options.pages.join("core.mjs")); }

/// Starts the server on a free loopback port and writes its session file.
pub fn start(options: Options) -> Result<Handle, String> {
    if !LANGUAGES.contains(&options.lang.as_str()) { return Err(format!("invalid language: {}", options.lang)); }
    configure_helper(&options);
    if !options.session.as_os_str().is_empty() { *locked(&SESSION_ENV) = Some(options.session.clone()); }
    let token = js::hex(&js::random::<16>()?);
    if options.sync_first { sync::sync(&options.file, &options.kit, "").map_err(|e| e.message)?; }
    let feed = Mutex::new(read_feed(&options.feed));
    // Where each file stands before anything can change it under the watcher.
    let watched = [options.file.clone(), core::working_path(&options.file), options.feed.clone()].map(|f| (stat(&f), f));
    let run_server = js::hex(&js::random::<4>()?);
    let listener = TcpListener::bind(("127.0.0.1", 0)).map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let server = Arc::new(Server { options, port, token, clients: Mutex::default(), feed, syncing: Mutex::default(), search_path: OnceLock::new(), run_server,
        closing: AtomicBool::new(false), connections: AtomicUsize::new(0) });
    server.mark_dead_runs().map_err(|e| e.message)?;
    let (accepting, watching) = (server.clone(), server.clone());
    spawn("todo-accept", move || accepting.accept(listener))?;
    spawn("todo-watch", move || watching.watch(watched))?;
    // The login shell is asked before anything needs its PATH.
    let asking = server.clone();
    let _ = spawn("todo-path", move || { asking.command_path(); });
    let handle = Handle { server: server.clone() };
    let session = server.options.session.clone();
    if !session.as_os_str().is_empty() {
        if let Err(error) = write_session(&session, port, &server.token, server.options.pid) { handle.close(); return Err(error.message); }
        let mut open = locked(&OPEN);
        // Windows has neither: a shell there closes the handle, and a leftover file fails the live check.
        #[cfg(unix)]
        if open.is_empty() {
            // SAFETY: at_exit only reads the list and removes files; registered once.
            unsafe { libc::atexit(at_exit); }
            clean_up_on_signals()?;
        }
        open.clear();
        open.push((session, server.token.clone()));
    }
    if !server.options.sync_first {
        let _ = spawn("todo-sync", move || { if let Err(error) = server.synced() { eprintln!("to-do sync: {error}"); } });
    }
    Ok(handle)
}
fn spawn(name: &str, work: impl FnOnce() + Send + 'static) -> Result<(), String> {
    std::thread::Builder::new().name(name.into()).spawn(work).map(|_| ()).map_err(|e| e.to_string())
}

// ---------- watching ----------
type Stat = Option<(Option<SystemTime>, i64, i64, u64, u64)>;
fn stat(file: &str) -> Stat {
    let meta = std::fs::metadata(file).ok()?;
    #[cfg(unix)]
    let (changed, changed_ns, inode) = { use std::os::unix::fs::MetadataExt; (meta.ctime(), meta.ctime_nsec(), meta.ino()) };
    #[cfg(not(unix))]
    let (changed, changed_ns, inode) = (meta.created().ok().and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok()).map_or(0, |d| d.as_nanos() as i64), 0, 0);
    Some((meta.modified().ok(), changed, changed_ns, inode, meta.len()))
}

impl Server {
    /// Polls the list, the working markers and the feed four times a second, as fs.watchFile does.
    fn watch(&self, mut files: [(Stat, String); 3]) {
        let mut expiry = self.next_expiry();
        let mut flush_at = Instant::now() + KEEPALIVE;
        while !self.closing.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(250));
            let mut changed = [false; 3];
            for (i, (known, file)) in files.iter_mut().enumerate() {
                let now = stat(file);
                changed[i] = now != *known;
                *known = now;
            }
            if changed[2] { *locked(&self.feed) = read_feed(&files[2].1); }
            let expired = expiry.is_some_and(|at| js::now_ms() >= at);
            if changed[1] || expired { expiry = self.next_expiry(); }
            if changed.contains(&true) || expired { self.broadcast(); }
            if Instant::now() >= flush_at { flush_at += KEEPALIVE; self.flush_finishes(); }
        }
    }
    /// When the oldest live working marker runs out.
    fn next_expiry(&self) -> Option<i64> {
        core::read_working(&self.options.file, js::now_ms()).iter().filter_map(|(_, mark)| helper::date(&mark.beat.lossy())).min().map(|at| at + core::working_ttl() + 50)
    }
    fn broadcast(&self) {
        let mut clients = locked(&self.clients);
        if clients.is_empty() { return; }
        let frame: Arc<str> = match self.frame() {
            Ok(payload) => payload.into(),
            Err(error) => format!("event: error\ndata: {}\n\n", error_json(&error.message)).into(),
        };
        clients.retain(|client| client.try_send(frame.clone()).is_ok());
    }

    // ---------- the list as every view shows it ----------
    fn command_path(&self) -> &str {
        self.search_path.get_or_init(|| {
            if !self.options.can_exec { return String::new(); }
            if let Some(path) = &self.options.search_path { return path.clone(); }
            #[cfg(unix)]
            return run::command_search_path();
            #[cfg(not(unix))]
            String::new()
        })
    }
    fn payload(&self) -> Result<String, Fail> { self.payload_with(|_| {}) }
    /// The list as an event.
    fn frame(&self) -> Result<String, Fail> {
        let mut out = self.payload_in("data: ", |_| {})?;
        out.push_str("\n\n");
        Ok(out)
    }
    fn payload_with(&self, extra: impl FnOnce(&mut String)) -> Result<String, Fail> { self.payload_in("", extra) }
    fn payload_in(&self, before: &str, extra: impl FnOnce(&mut String)) -> Result<String, Fail> {
        let model = core::load(&self.options.file)?;
        let versions = core::versions(&model)?;
        let working = core::read_working(&self.options.file, js::now_ms());
        let mut out = format!("{before}{{\"items\":[");
        for (i, item) in model.items.iter().enumerate() {
            if i > 0 { out.push(','); }
            let mark = working.iter().find(|(id, _)| !item.done && *id == item.id.as_str().into()).map(|(_, mark)| mark);
            self.item_json(item, &versions[i], mark).write(&mut out);
        }
        out.push_str("],\"file\":");
        json::quote(&self.options.file, &mut out);
        out.push_str(",\"lang\":");
        json::quote(&self.options.lang, &mut out);
        let feed = locked(&self.feed).clone();
        out.push_str(",\"feed\":");
        out.push_str(&feed.json);
        if !feed.error.is_empty() { out.push_str(",\"feedError\":"); json::quote(feed.error, &mut out); }
        extra(&mut out);
        out.push('}');
        Ok(out)
    }
    /// The item's fields in the order core.parse and the payload of todo/web.mjs write them.
    fn item_json(&self, item: &Item, version: &str, mark: Option<&core::Mark>) -> Json {
        let s = |text: &str| Json::str(text);
        let list = |texts: &[String]| Json::Arr(texts.iter().map(|t| Json::str(t)).collect());
        let mut out = vec![
            ("id", s(&item.id)), ("title", s(&item.title)), ("done", Json::Bool(item.done)), ("project", s(&item.project)),
            ("link", item.link.as_ref().map_or(Json::Null, |(label, url)| object(vec![("label", s(label)), ("url", s(url))]))),
            ("sdlc", item.sdlc.as_ref().map_or(Json::Null, |d| object(vec![("slug", s(&d.slug)), ("phase", s(&d.phase)), ("state", s(&d.state)), ("action", s(&d.action))]))),
            ("waiting", s(&item.waiting)), ("others", s(&item.others)), ("brief", s(&item.brief)), ("repos", list(&item.repos)), ("choices", list(&item.choices)),
            ("pick", item.pick.map_or(Json::Null, |p| Json::Num(p as f64))), ("suggest", s(&item.suggest)), ("run", s(&item.run)),
            ("exec", item.exec.as_ref().map_or(Json::Null, core::Exec::json)), ("execResult", item.exec_result.clone().unwrap_or(Json::Null)), ("pin", Json::Bool(item.pin)),
            ("events", Json::Arr(item.events.iter().map(|e| object(vec![("at", s(&e.at)), ("who", s(&e.who)), ("what", s(&e.what))])).collect())),
            ("notes", list(&item.notes)),
        ];
        if item.checked_open { out.push(("checkedOpen", Json::Bool(true))); }
        if item.relative { out.push(("error", s(core::RELATIVE_PROJECT))); }
        let status = match item.status { Status::Done => "done", Status::Blocked => "blocked", Status::Waiting => "waiting", Status::Others => "others", Status::Workable => "workable" };
        out.extend([("status", s(status)), ("unread", Json::Num(item.unread as f64)), ("fixRequested", Json::Bool(item.fix_requested)), ("working", mark.map_or(Json::Null, core::Mark::json))]);
        if let Some(exec) = &item.exec {
            let path = if self.options.can_exec { run::resolve_command(&exec.argv[0].lossy(), self.command_path()) } else { String::new() };
            out.push(("execPath", s(&path)));
            if !self.options.can_exec { out.push(("execUnsupported", Json::Bool(true))); }
        }
        out.push(("version", s(version)));
        out.push(("turn", turn(item, mark.is_some())));
        object(out)
    }

    /// One sync at a time; readers that arrive meanwhile share its result.
    fn synced(&self) -> Result<(), String> {
        let (flight, mine) = {
            let mut syncing = locked(&self.syncing);
            match syncing.as_ref() { Some(flight) => (flight.clone(), false), None => { let flight = Sync::default(); *syncing = Some(flight.clone()); (flight, true) } }
        };
        if mine {
            let work = std::panic::AssertUnwindSafe(|| sync::sync(&self.options.file, &self.options.kit, "").map_err(|e| e.message));
            let result = std::panic::catch_unwind(work).unwrap_or_else(|_| Err("sync failed".into()));
            *locked(&self.syncing) = None;
            *locked(&flight.0) = Some(result.clone());
            flight.1.notify_all();
            return result;
        }
        let mut result = locked(&flight.0);
        loop {
            if let Some(result) = result.as_ref() { return result.clone(); }
            result = flight.1.wait(result).unwrap_or_else(|e| e.into_inner());
        }
    }

    // ---------- connections ----------
    fn accept(self: Arc<Server>, listener: TcpListener) {
        for stream in listener.incoming() {
            if self.closing.load(Ordering::SeqCst) { return; }
            let Ok(stream) = stream else { std::thread::sleep(Duration::from_millis(50)); continue };
            if self.connections.fetch_add(1, Ordering::SeqCst) >= CONNECTIONS { self.connections.fetch_sub(1, Ordering::SeqCst); continue; }
            let server = self.clone();
            let started = spawn("todo-http", move || {
                struct Leave<'a>(&'a Server);
                impl Drop for Leave<'_> { fn drop(&mut self) { self.0.connections.fetch_sub(1, Ordering::SeqCst); } }
                let _leave = Leave(&server);
                server.serve(stream);
            });
            if started.is_err() { self.connections.fetch_sub(1, Ordering::SeqCst); }
        }
    }
    fn serve(&self, mut stream: TcpStream) {
        let _ = stream.set_nodelay(true);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(60)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(30)));
        let mut request = match http::read_request(&mut stream) {
            Ok(request) => request,
            Err(http::Bad::Closed) => return,
            Err(http::Bad::Status(status)) => return http::refuse(&mut stream, status),
        };
        // Liveness answers at once: a result waiting for a busy lock must not make this server look gone.
        if request.path != "/api/live" { self.flush_finishes(); }
        if request.http11 && request.all("host").is_empty() { return http::refuse(&mut stream, 400); }
        if request.method == "CONNECT" { return; }
        let body = request.method != "HEAD";
        match self.route(&mut request, &mut stream) {
            Ok(Reply::Json(text)) => http::answer(&mut stream, 200, JSON, text.as_bytes(), body),
            Ok(Reply::File(kind, bytes)) => http::answer(&mut stream, 200, kind, &bytes, body),
            Ok(Reply::Error(status, text)) => http::answer(&mut stream, status, JSON, error_json(&text).as_bytes(), body),
            Ok(Reply::Done) => {}
            Err(error) if error.status == 403 => http::answer(&mut stream, 403, "text/plain; charset=utf-8", b"Forbidden\n", body),
            Err(error) => http::answer(&mut stream, if error.status == 0 { 400 } else { error.status }, JSON, error_json(&error.message).as_bytes(), body),
        }
    }
    fn authorized(&self, value: Option<&str>) -> bool {
        // Constant time over the token's length.
        value.is_some_and(|v| v.len() == self.token.len() && v.bytes().zip(self.token.bytes()).fold(0, |diff, (a, b)| diff | (a ^ b)) == 0)
    }
    fn route(&self, request: &mut http::Request, stream: &mut TcpStream) -> Result<Reply, Fail> {
        let hosts = [format!("127.0.0.1:{}", self.port), format!("localhost:{}", self.port)];
        let forbidden = || Fail::at(403, "Forbidden");
        if !request.only("host").is_some_and(|host| hosts.iter().any(|h| h == host)) { return forbidden(); }
        let path = request.path.clone();
        if (path == "/api" || path.starts_with("/api/")) && !self.authorized(request.only("x-todo-token")) { return forbidden(); }
        if path == "/events" && !self.authorized(request.param("t").as_deref()) { return forbidden(); }
        if request.method != "GET" {
            let origin = request.only("origin").and_then(|o| o.strip_prefix("http://"));
            let json = request.all("content-type").first().is_some_and(|kind| js::trim(kind.split(';').next().unwrap_or("")).eq_ignore_ascii_case("application/json"));
            if !origin.is_some_and(|o| hosts.iter().any(|h| h == o)) || !json { return forbidden(); }
            return self.change(request, stream, &path);
        }
        if let Some((name, kind)) = asset(&path) {
            let file = self.options.pages.join(name);
            return std::fs::read(&file).map(|bytes| Reply::File(kind, bytes)).map_err(|e| Fail::io(&e, "open", &file.to_string_lossy()));
        }
        match path.as_str() {
            "/api/live" => Ok(Reply::Json("{\"ok\":true}".into())),
            "/api/feed" => {
                let feed = locked(&self.feed).clone();
                let mut out = format!("{{\"feed\":{},\"error\":", feed.json);
                json::quote(feed.error, &mut out);
                out.push('}');
                Ok(Reply::Json(out))
            }
            "/api/items" => { self.synced().map_err(Fail::new)?; self.payload().map(Reply::Json) }
            "/api/artifact" => self.artifact(request.param("id")).map(Reply::Json),
            "/events" => self.events(request, stream),
            _ => Ok(Reply::Error(404, "not found".into())),
        }
    }
    fn events(&self, request: &http::Request, stream: &mut TcpStream) -> Result<Reply, Fail> {
        use std::io::Write;
        let (send, frames) = mpsc::sync_channel::<Arc<str>>(BACKLOG);
        {
            let mut clients = locked(&self.clients);
            let first: Arc<str> = self.frame()?.into();
            let _ = send.try_send(first);
            if !self.closing.load(Ordering::SeqCst) { clients.push(send); }
        }
        let chunked = request.http11;
        let coding = if chunked { "Transfer-Encoding: chunked\r\n" } else { "" };
        let head = format!("HTTP/1.1 200 OK\r\n{}Content-Type: text/event-stream; charset=utf-8\r\nConnection: keep-alive\r\n{coding}\r\n", http::HEADERS);
        if stream.write_all(head.as_bytes()).is_err() { return Ok(Reply::Done); }
        let mut write = |text: &str| {
            let size = if chunked { format!("{:x}\r\n", text.len()) } else { String::new() };
            let parts: [&[u8]; 3] = [size.as_bytes(), text.as_bytes(), if chunked { b"\r\n" } else { b"" }];
            let sent = parts.into_iter().all(|part| stream.write_all(part).is_ok());
            sent
        };
        let mut tick = Instant::now() + KEEPALIVE;
        loop {
            match frames.recv_timeout(tick.saturating_duration_since(Instant::now())) {
                Ok(frame) => if !write(&frame) { break; },
                Err(mpsc::RecvTimeoutError::Timeout) => { tick += KEEPALIVE; if !write(": keepalive\n\n") { break; } }
                // Dropped: the server is closing, or this stream fell too far behind.
                Err(mpsc::RecvTimeoutError::Disconnected) => { if chunked { let _ = stream.write_all(b"0\r\n\r\n"); } break; }
            }
        }
        Ok(Reply::Done)
    }
}

const JSON: &str = "application/json; charset=utf-8";
enum Reply { Json(String), File(&'static str, Vec<u8>), Error(u16, String), Done }
fn error_json(message: &str) -> String { object(vec![("error", Json::str(message))]).stringify() }

/// The files the page may load; nothing else is served.
fn asset(path: &str) -> Option<(&'static str, &'static str)> {
    const JS: &str = "text/javascript; charset=utf-8";
    Some(match path {
        "/" => ("page/index.html", "text/html; charset=utf-8"),
        "/app.js" => ("page/app.js", JS),
        "/app.css" => ("page/app.css", "text/css; charset=utf-8"),
        "/markdown.js" => ("page/markdown.js", JS),
        "/board.js" => ("page/board.js", JS),
        "/favicon.png" => ("app/AppIcon.png", "image/png"),
        "/i18n.mjs" => ("i18n.mjs", JS),
        "/status.mjs" => ("status.mjs", JS),
        "/locales/en.mjs" => ("locales/en.mjs", JS),
        "/locales/ko.mjs" => ("locales/ko.mjs", JS),
        _ => return None,
    })
}

/// statusOf in todo/status.mjs.
fn turn(item: &Item, working: bool) -> Json {
    let make = |actor: &str, kind: &str| object(vec![("actor", Json::str(actor)), ("kind", Json::str(kind))]);
    match item.status {
        Status::Done => make("done", "done"),
        Status::Blocked if item.fix_requested => make("agent", "handoff"),
        Status::Blocked => make("blocked", "blocked"),
        Status::Waiting => {
            let gate = gate_of(item, true);
            let kind = if gate.is_empty() { "answer".into() } else { format!("approve-{gate}") };
            object(vec![("actor", Json::str("you")), ("kind", Json::str(&kind)), ("gate", Json::str(gate))])
        }
        Status::Others => make("others", "others"),
        _ if working => make("agent", "working"),
        _ if item.unread > 0 => make("agent", "handoff"),
        _ => make("agent", if item.sdlc.is_some() { "agent" } else { "new" }),
    }
}
/// The gate an item waits at. The page's turn takes one space after "approve", the approval any blank.
fn gate_of(item: &Item, one_space: bool) -> &'static str {
    match &item.sdlc { Some(s) if s.state == "NEEDS-HUMAN" => js::gate(&s.action, one_space), _ => "" }
}

/// A request value as a trimmed line of at most `max` characters.
fn line(value: Option<&Json>, name: &str, max: usize) -> Result<String, Fail> {
    let text = value.and_then(Json::text).filter(|t| !js::trim(t).is_empty() && js::units(js::trim(t)) <= max && !t.contains(['\r', '\n']));
    match text { Some(text) => Ok(js::trim(&text).into()), None => Fail::at(400, format!("invalid {name}")) }
}

impl Server {
    fn change(&self, request: &mut http::Request, stream: &mut TcpStream, path: &str) -> Result<Reply, Fail> {
        let body = match request.body(stream) {
            Ok(Some(bytes)) => bytes,
            Ok(None) => return Fail::at(413, "body too large"),
            Err(http::Bad::Closed) => return Fail::at(400, "request aborted"),
            Err(http::Bad::Status(status)) => return Fail::at(status, "invalid request body"),
        };
        let Some(body @ Json::Obj(_)) = json::parse(&String::from_utf8_lossy(&body)) else { return Fail::at(400, "invalid JSON object") };
        if request.method != "POST" { return Ok(Reply::Error(405, "method not allowed".into())); }
        let file = self.options.file.as_str();
        let (id, version) = (body.get("id").and_then(Json::text), body.get("version").and_then(Json::text));
        let (id, version) = (id.as_deref(), version.as_deref());
        let mut launch = None;
        match path {
            "/api/exec" => {
                let result = self.run_item(id, version, body.get("path").and_then(Json::text).as_deref())?;
                return self.payload_with(|out| { out.push_str(",\"exec\":"); result.write(out); }).map(Reply::Json);
            }
            "/api/items" => core::add(file, &line(body.get("text"), "text", usize::MAX)?)?,
            "/api/item" => match body.get("op").and_then(Json::text).as_deref() {
                Some("edit") => core::edit(file, id, version, &line(body.get("title"), "title", usize::MAX)?)?,
                Some("move") => match body.get("delta") {
                    Some(Json::Num(delta)) if delta.abs() == 1.0 => core::move_by(file, id, version, *delta as i64)?,
                    _ => return Fail::at(400, "invalid delta"),
                },
                Some("done") => core::done(file, id, version)?,
                Some("undone") => core::undone(file, id, version)?,
                Some("delete") => core::remove(file, id, version)?,
                Some("reply") => core::reply(file, id, version, &line(body.get("text"), "reply", usize::MAX)?)?,
                Some("fix") => launch = Some(self.fix(id, version)?),
                _ => return Fail::at(400, "invalid operation"),
            },
            "/api/approve" => self.approve(&body, id, version)?,
            _ => return Ok(Reply::Error(404, "not found".into())),
        }
        self.payload_with(|out| if let Some(launch) = launch { out.push_str(",\"launch\":"); json::quote(&launch, out); }).map(Reply::Json)
    }

    /// Records the fix request and starts the agent todo-agent.json names, if it names one.
    fn fix(&self, id: Option<&str>, version: Option<&str>) -> Result<String, Fail> {
        let file = &self.options.file;
        let (id, project) = core::request_fix(file, id, version)?;
        let config = std::env::var("SDLC_TODO_AGENT").ok().filter(|v| !v.is_empty()).unwrap_or_else(|| js::join(&js::dirname(file), &["todo-agent.json"]));
        let text = match std::fs::read(&config) {
            Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok("queued".into()),
            Err(e) => return Ok(format!("failed: invalid {config}: {}", Fail::io(&e, "open", &config).message)),
        };
        let Some(value) = json::parse(&text) else { return Ok(format!("failed: invalid {config}: {}", helper::json_error(&text))) };
        let argv = match value.get("fix") {
            None => return Ok("queued".into()),
            Some(Json::Arr(list)) => list.iter().map(|v| v.text().filter(|t| !t.is_empty())).collect::<Option<Vec<_>>>().filter(|l| !l.is_empty()),
            Some(_) => None,
        };
        let Some(argv) = argv else { return Ok(format!("failed: {config}: fix must be a non-empty array of strings")) };
        // Node passes the kit folder with its closing slash.
        let kit = format!("{}{}", self.options.kit, if self.options.kit.ends_with(['/', '\\']) { "" } else { std::path::MAIN_SEPARATOR_STR });
        let argv: Vec<String> = argv.iter().map(|arg| fill(arg, &[("id", &id), ("kit", &kit), ("project", &project)])).collect();
        let cwd = if js::is_absolute(&project) && Path::new(&project).exists() { project } else { js::home() };
        run::launch(&argv, &cwd)
    }

    // ---------- documents and approvals ----------
    /// The store sdlc.sh uses for the item; the status is the answer's when that fails.
    fn project_store(&self, item: &Item) -> Result<String, (u16, run::Failed)> {
        let plain = |status, message: String| (status, run::Failed { message, stderr: String::new() });
        let slug = item.sdlc.as_ref().map_or("", |s| s.slug.as_str());
        let stdout = sync::status(&self.options.kit, &item.project, slug).map_err(|f| (400, f))?;
        let Some(value) = json::parse(&stdout) else { return Err(plain(400, helper::json_error(&stdout))) };
        match value.get("store").and_then(Json::text).filter(|s| !s.is_empty()) {
            Some(store) => run::native_path(&store).map_err(|f| (400, f)),
            None => Err(plain(409, "status did not report a store".into())),
        }
    }
    fn item_for(&self, id: Option<&str>) -> Result<Item, Fail> {
        let Some(id) = id else { return Fail::at(400, "invalid id") };
        let mut model: Model = core::load(&self.options.file)?;
        match model.by_id(id) { Some(at) => Ok(model.items.swap_remove(at)), None => Fail::at(404, "item not found") }
    }
    fn artifact(&self, id: Option<String>) -> Result<String, Fail> {
        let mut item = self.item_for(id.as_deref())?;
        if item.brief.is_empty() || item.sdlc.is_some() {
            sync::sync(&self.options.file, &self.options.kit, &item.id)?;
            item = self.item_for(id.as_deref())?;
        }
        if !item.brief.is_empty() && gate_of(&item, false).is_empty() { return brief(&item); }
        core::project_path(&item.project)?;
        let Some(sdlc) = item.sdlc.as_ref().filter(|s| !item.done && !item.project.is_empty() && is_slug(&s.slug)) else { return Fail::at(409, "item has no work document") };
        let gate = gate_of(&item, false);
        let store = self.project_store(&item).or_else(|(status, failed)| Fail::at(status, failed.message))?;
        let mut folder = js::join(&store, &["work", &sdlc.slug]);
        if !Path::new(&folder).exists() { folder = js::join(&store, &["archive", &sdlc.slug]); }
        // Without a gate, show the plan once one exists, otherwise the intent.
        let plan = if gate.is_empty() { sdlc.phase != "intent" && Path::new(&js::join(&folder, &["PLAN.md"])).exists() } else { gate == "plan" };
        let file = js::join(&folder, &[if plan { "PLAN.md" } else { "intent.md" }]);
        let bytes = std::fs::read(&file).map_err(|e| Fail::io(&e, "open", &file))?;
        Ok(document(gate, &file, &bytes))
    }
    fn approve(&self, body: &Json, id: Option<&str>, version: Option<&str>) -> Result<(), Fail> {
        let blank = match body.get("words") { None => true, Some(Json::Str(words)) => js::trim(&words.lossy()).is_empty(), _ => false };
        let typed = if blank { String::new() } else { line(body.get("words"), "words", 500)? };
        let (gate, sha) = (body.get("gate").and_then(Json::text).unwrap_or_default(), body.get("sha").and_then(Json::text).unwrap_or_default());
        if !matches!(gate.as_str(), "intent" | "plan") || sha.len() != 64 || !sha.bytes().all(|b| b.is_ascii_hexdigit()) { return Fail::at(400, "invalid approval"); }
        let words = if typed.is_empty() { format!("approved as shown in the to-do web page (version {})", sha[..12].to_ascii_lowercase()) } else { typed };
        let kit = &self.options.kit;
        core::update(&self.options.file, id, version, &mut |model, at| {
            let item = &mut model.items[at];
            core::project_path(&item.project)?;
            let shown = gate_of(item, false);
            let slug = item.sdlc.as_ref().map_or("", |s| s.slug.as_str()).to_string();
            if item.done || shown.is_empty() || item.project.is_empty() || !is_slug(&slug) { return Fail::at(409, "item has no approval gate"); }
            if shown != gate { return Fail::at(409, "approval gate changed"); }
            let store = self.project_store(item).or_else(|(_, failed)| Fail::at(409, failed.text()))?;
            run::exec_file("bash", &[&sync::script(kit), "approve", &gate, &slug, "--human", &words, "--sha", &sha], Some(&js::dirname(&store)))
                .or_else(|failed| Fail::at(409, failed.text()))?;
            item.events.push(core::Event { at: js::stamp(), who: "human".into(), what: format!("approved {gate} — \"{words}\"") });
            Ok(())
        })?;
        sync::sync(&self.options.file, kit, "")
    }
}

fn is_slug(slug: &str) -> bool {
    let ok = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit();
    slug.len() <= 80 && slug.bytes().next().is_some_and(ok) && slug.bytes().all(|b| ok(b) || b"._-".contains(&b))
}
/// `{name}` replaced by its value, once over the text.
fn fill(text: &str, values: &[(&str, &str)]) -> String {
    let (mut out, mut rest) = (String::new(), text);
    while let Some(at) = rest.find('{') {
        out.push_str(&rest[..at]);
        rest = &rest[at..];
        match values.iter().find(|(name, _)| rest[1..].strip_prefix(name).is_some_and(|r| r.starts_with('}'))) {
            Some((name, value)) => { out.push_str(value); rest = &rest[name.len() + 2..]; }
            None => { out.push('{'); rest = &rest[1..]; }
        }
    }
    out.push_str(rest);
    out
}
fn document(gate: &str, file: &str, bytes: &[u8]) -> String {
    object(vec![("gate", Json::str(gate)), ("file", Json::str(file)), ("markdown", Json::str(&String::from_utf8_lossy(bytes))), ("sha", Json::str(&js::sha256(bytes)))]).stringify()
}
fn brief(item: &Item) -> Result<String, Fail> {
    if item.done { return Fail::at(409, "item has no work document"); }
    if !js::is_absolute(&item.brief) { return Fail::at(409, "brief must be an absolute path"); }
    match std::fs::read(&item.brief) {
        Ok(bytes) => Ok(document("", &item.brief, &bytes)),
        Err(e) => Fail::at(if e.kind() == std::io::ErrorKind::NotFound { 404 } else { 409 }, format!("brief not readable: {}", item.brief)),
    }
}
