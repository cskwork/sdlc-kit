//! The to-do web server as a library: the routes, checks and answers of todo/web.mjs, so a shell runs no Node
//! server. The CLI and TUI keep todo.mjs; both write the same files under the same lock (core.rs). A shell calls
//! `find_or_start`, talks HTTP to 127.0.0.1 with the token, and calls `Handle::close` before it exits.
// A panic must stay in its thread: the locks tolerate it, the guards undo it, and the watcher goes on.
#[cfg(panic = "abort")]
compile_error!("sdlc-todo-server needs panic = \"unwind\"");

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
const CONNECTIONS: usize = 128;
/// Connections that have not shown the token; the oldest makes room, so they cannot keep others out.
const STRANGERS: usize = 64;

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

fn setting(name: &str) -> Option<String> { js::env(name).filter(|v| !v.is_empty()) }
/// The list and the session file, as core.todoPath and core.sessionPath name them.
pub fn todo_path() -> String { setting("SDLC_TODO").unwrap_or_else(|| js::join(&js::home(), &[".sdlc", "todo.md"])) }
pub fn session_path() -> PathBuf { setting("SDLC_TODO_SESSION").unwrap_or_else(|| js::join(&js::dirname(&todo_path()), &["todo-web.json"])).into() }

impl Options {
    /// The server `todo.mjs serve` would be: the list from the environment, pages and scripts from the kit.
    pub fn for_kit(kit: &Path, session: &Path, node: &str, lang: &str) -> Options {
        let file = todo_path();
        // Node resolves the kit through links, and its path is part of the error words in the list.
        let kit = plain(std::fs::canonicalize(kit).unwrap_or_else(|_| kit.into()));
        Options {
            feed: setting("SDLC_TODO_FEED").unwrap_or_else(|| js::join(&js::dirname(&file), &["todo-feed.json"])),
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
    /// What this server writes; closed with it.
    list: core::List,
    /// Held while a frame is built and queued, so frames arrive in the order they were built; close() never takes it.
    publishing: Mutex<()>,
    /// Open event streams.
    clients: Mutex<Vec<mpsc::SyncSender<Arc<str>>>>,
    feed: Mutex<Feed>,
    syncing: Mutex<Option<Sync>>,
    search_path: OnceLock<String>,
    /// This server's nonce: it knows its own runs, whatever process id they carry.
    run_server: String,
    closing: AtomicBool,
    /// Something was left out of a frame or an answer; the watcher sends the whole list when it can.
    incomplete: AtomicBool,
    connections: AtomicUsize,
    strangers: Mutex<std::collections::VecDeque<Arc<TcpStream>>>,
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
        self.server.list.close();
        remove_session(&self.server.options.session, &self.server.token);
        locked(&self.server.clients).clear();
        // Wakes the accept loop so it sees that it is closing.
        let _ = TcpStream::connect_timeout(&([127, 0, 0, 1], self.server.port).into(), Duration::from_millis(200));
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
    }
    // The reader first: a handler without one would swallow the signal.
    spawn("todo-signal", move || {
        let mut byte = 0u8;
        // SAFETY: reads one byte; then the default action ends the process.
        while unsafe { libc::read(ends[0], (&raw mut byte).cast(), 1) } != 1 {}
        remove_open_sessions();
        let_writes_finish();
        unsafe { libc::signal(byte as i32, libc::SIG_DFL); libc::kill(libc::getpid(), byte as i32); }
    })?;
    // SAFETY: the handler only writes to the pipe.
    unsafe { for signal in [libc::SIGTERM, libc::SIGINT] { libc::signal(signal, on_signal as *const () as libc::sighandler_t); } }
    Ok(())
}

pub fn configure_helper(options: &Options) { helper::configure(&options.node, &options.pages.join("core.mjs")); }

/// Starts the server on a free loopback port and writes its session file.
pub fn start(options: Options) -> Result<Handle, String> {
    if !LANGUAGES.contains(&options.lang.as_str()) { return Err(format!("invalid language: {}", options.lang)); }
    configure_helper(&options);
    if !options.session.as_os_str().is_empty() { *locked(&SESSION_ENV) = Some(options.session.clone()); }
    let token = js::hex(&js::random::<16>()?);
    let list = core::List::new(&options.file);
    if options.sync_first { sync::sync(&list, &options.kit, "").map_err(|e| e.message)?; }
    let feed = Mutex::new(read_feed(&options.feed));
    // Where each file stands before anything can change it under the watcher.
    let watched = [options.file.clone(), core::working_path(&options.file), options.feed.clone()].map(|f| (stat(&f), f));
    let run_server = js::hex(&js::random::<4>()?);
    let listener = TcpListener::bind(("127.0.0.1", 0)).map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let server = Arc::new(Server { options, port, token, list, publishing: Mutex::default(), clients: Mutex::default(), feed, syncing: Mutex::default(), search_path: OnceLock::new(), run_server,
        closing: AtomicBool::new(false), incomplete: AtomicBool::new(false), connections: AtomicUsize::new(0), strangers: Mutex::default() });
    server.mark_dead_runs().map_err(|e| e.message)?;
    let handle = Handle { server };
    match begin(&handle.server, listener, watched) {
        Ok(()) => Ok(handle),
        Err(error) => { handle.close(); Err(error) }
    }
}
/// Starts the threads and shares the session; on an error the caller closes the server, which ends those that started.
fn begin(server: &Arc<Server>, listener: TcpListener, watched: [(Stat, String); 3]) -> Result<(), String> {
    let (accepting, watching) = (server.clone(), server.clone());
    spawn("todo-accept", move || accepting.accept(listener))?;
    spawn("todo-watch", move || watching.watch(watched))?;
    // The login shell is asked before anything needs its PATH.
    let asking = server.clone();
    let _ = spawn("todo-path", move || { asking.command_path(); });
    let session = server.options.session.clone();
    if !session.as_os_str().is_empty() {
        let mut open = locked(&OPEN);
        // Windows has neither: a shell there closes the handle, and a leftover file fails the live check.
        #[cfg(unix)]
        if open.is_empty() {
            clean_up_on_signals()?;
            // SAFETY: at_exit only reads the list and removes files; registered once.
            unsafe { libc::atexit(at_exit); }
        }
        // An earlier server's entry goes only once this one's file took its place; removal checks the token anyway.
        open.push((session.clone(), server.token.clone()));
        drop(open);
        write_session(&session, server.port, &server.token, server.options.pid).map_err(|e| e.message)?;
        let mut open = locked(&OPEN);
        let newest = open.len() - 1;
        open.drain(..newest);
    }
    if !server.options.sync_first {
        let server = server.clone();
        let _ = spawn("todo-sync", move || { if let Err(error) = server.synced() { eprintln!("to-do sync: {error}"); } });
    }
    Ok(())
}
fn spawn(name: &str, work: impl FnOnce() + Send + 'static) -> Result<(), String> {
    std::thread::Builder::new().name(name.into()).spawn(work).map(|_| ()).map_err(|e| e.to_string())
}

// ---------- watching ----------
const RETRY_FIRST: Duration = Duration::from_secs(1);
const RETRY_MOST: Duration = Duration::from_secs(30);
/// When the watcher next has something to do besides a changed file: a marker runs out, or a change not yet shown is tried again.
struct View { expiry: Option<i64>, retry: Option<(Instant, Duration)>, flush_at: Instant }
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
        // The first look works the expiry out, and repeats it until it can.
        let mut view = View { expiry: None, retry: Some((Instant::now(), RETRY_FIRST)), flush_at: Instant::now() + KEEPALIVE };
        while !self.closing.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(250));
            let round = std::panic::AssertUnwindSafe(|| self.look(&mut files, &mut view));
            // The next round goes on from the state this one left.
            if std::panic::catch_unwind(round).is_err() { eprintln!("to-do watcher: a round failed"); }
        }
    }
    fn look(&self, files: &mut [(Stat, String); 3], view: &mut View) {
        let mut changed = [false; 3];
        for (i, (known, file)) in files.iter_mut().enumerate() {
            let now = stat(file);
            changed[i] = now != *known;
            *known = now;
        }
        if changed[2] { *locked(&self.feed) = read_feed(&files[2].1); }
        let news = changed.contains(&true) || view.expiry.is_some_and(|at| js::now_ms() >= at);
        // A frame or answer that had to leave something out asks for the whole list later.
        if self.incomplete.swap(false, Ordering::SeqCst) && view.retry.is_none() { view.retry = Some((Instant::now() + RETRY_FIRST, RETRY_FIRST)); }
        let due = view.retry.filter(|(at, _)| Instant::now() >= *at);
        if news || due.is_some() {
            // Until it is shown, a change stays pending: one that fails (a Node helper in trouble) or panics is tried again.
            let wait = due.or(view.retry).map_or(RETRY_FIRST, |(_, wait)| wait);
            view.retry = Some((Instant::now() + wait, (wait * 2).min(RETRY_MOST)));
            view.expiry = self.next_expiry();
            if self.broadcast(news) { view.retry = None; }
            // Waiting starts once the attempt ended: it may itself have taken long.
            else { view.retry = Some((Instant::now() + wait, (wait * 2).min(RETRY_MOST))); }
        }
        if Instant::now() >= view.flush_at { view.flush_at += KEEPALIVE; self.flush_finishes(); }
        run::reap();
    }
    /// When the oldest live working marker runs out.
    fn next_expiry(&self) -> Option<i64> {
        core::read_working(&self.options.file, js::now_ms()).live.iter().map(|(_, mark)| mark.at).min().map(|at| at + core::working_ttl() + 50)
    }
    /// Sends the list to every stream; false when it could not be built whole. `report`: the streams get what there is,
    /// or why there is nothing; a later try stays silent until it has the whole list.
    fn broadcast(&self, report: bool) -> bool {
        let _one = locked(&self.publishing);
        if locked(&self.clients).is_empty() { return true; }
        self.incomplete.store(false, Ordering::SeqCst);
        let frame = self.frame();
        let built = frame.is_ok() && !self.incomplete.swap(false, Ordering::SeqCst);
        if !built && !report { return false; }
        let frame: Arc<str> = match frame {
            Ok(payload) => payload.into(),
            Err(error) => format!("event: error\ndata: {}\n\n", error_json(&error.message)).into(),
        };
        locked(&self.clients).retain(|client| client.try_send(frame.clone()).is_ok());
        built
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
    /// The answer to a stored change. The list shows it; one that cannot be built now is left out (the page then waits
    /// for its stream) and never turns the answer into an error, or the person would send the change again.
    fn stored(&self, extra: impl Fn(&mut String)) -> Reply {
        let built = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.payload_with(&extra)));
        if let Ok(Ok(text)) = built { return Reply::Json(text); }
        self.incomplete.store(true, Ordering::SeqCst);
        let mut out = String::from("{\"file\":");
        json::quote(&self.options.file, &mut out);
        extra(&mut out);
        out.push('}');
        Reply::Json(out)
    }
    fn payload_in(&self, before: &str, extra: impl FnOnce(&mut String)) -> Result<String, Fail> {
        let model = core::load(&self.options.file)?;
        let versions = core::versions(&model)?;
        let core::Working { live: working, unread } = core::read_working(&self.options.file, js::now_ms());
        if unread { self.incomplete.store(true, Ordering::SeqCst); }
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
            let work = std::panic::AssertUnwindSafe(|| sync::sync(&self.list, &self.options.kit, "").map_err(|e| e.message));
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
            let Ok(stream) = stream else { self.make_room(); std::thread::sleep(Duration::from_millis(50)); continue };
            let full = self.connections.load(Ordering::SeqCst) >= CONNECTIONS;
            if (full || locked(&self.strangers).len() >= STRANGERS) && !self.make_room() && full { continue; }
            self.connections.fetch_add(1, Ordering::SeqCst);
            let (server, stream) = (self.clone(), Arc::new(stream));
            locked(&self.strangers).push_back(stream.clone());
            let guest = Guest { server, stream };
            let _ = spawn("todo-http", move || guest.server.serve(&guest.stream));
        }
    }
    /// Closes the oldest connection that has not shown the token.
    fn make_room(&self) -> bool {
        let oldest = locked(&self.strangers).pop_front();
        oldest.is_some_and(|stream| { let _ = stream.shutdown(std::net::Shutdown::Both); true })
    }
    fn known(&self, stream: &TcpStream) { locked(&self.strangers).retain(|other| !std::ptr::eq(&**other, stream)); }
    fn serve(&self, stream: &TcpStream) {
        let mut stream = stream;
        let _ = stream.set_nodelay(true);
        let _ = stream.set_write_timeout(Some(Duration::from_secs(30)));
        let mut request = match http::read_request(&mut stream) {
            Ok(request) => request,
            Err(http::Bad::Closed) => return,
            Err(http::Bad::Status(status)) => return http::refuse(&mut stream, status),
        };
        if self.closing.load(Ordering::SeqCst) { return http::refuse(&mut stream, 503); }
        if request.http11 && request.all("host").is_empty() { return http::refuse(&mut stream, 400); }
        if request.method == "CONNECT" { return; }
        let reply = self.route(&mut request, &mut stream);
        let answer = |stream: &mut &TcpStream, status, kind, content: &[u8]| http::answer(stream, &request, status, kind, content);
        match reply {
            Ok(Reply::Json(text)) => answer(&mut stream, 200, JSON, text.as_bytes()),
            Ok(Reply::File(kind, bytes)) => answer(&mut stream, 200, kind, &bytes),
            Ok(Reply::Error(status, text)) => answer(&mut stream, status, JSON, error_json(&text).as_bytes()),
            Ok(Reply::Done) => {}
            Err(error) if error.status == 403 => answer(&mut stream, 403, "text/plain; charset=utf-8", b"Forbidden\n"),
            Err(error) => answer(&mut stream, if error.status == 0 { 400 } else { error.status }, JSON, error_json(&error.message).as_bytes()),
        }
    }
    fn authorized(&self, value: Option<&str>) -> bool {
        // Constant time over the token's length.
        value.is_some_and(|v| v.len() == self.token.len() && v.bytes().zip(self.token.bytes()).fold(0, |diff, (a, b)| diff | (a ^ b)) == 0)
    }
    fn route(&self, request: &mut http::Request, stream: &mut &TcpStream) -> Result<Reply, Fail> {
        let hosts = [format!("127.0.0.1:{}", self.port), format!("localhost:{}", self.port)];
        let forbidden = || Fail::at(403, "Forbidden");
        if !request.only("host").is_some_and(|host| hosts.iter().any(|h| h == host)) { return forbidden(); }
        let path = request.path.clone();
        if (path == "/api" || path.starts_with("/api/")) && !self.authorized(request.only("x-todo-token")) { return forbidden(); }
        if path == "/events" && !self.authorized(request.param("t").as_deref()) { return forbidden(); }
        if path.starts_with("/api/") || path == "/events" {
            self.known(stream);
            // Liveness answers at once: a result waiting for a busy lock must not make this server look gone.
            if path != "/api/live" { self.flush_finishes(); }
        }
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
    fn events(&self, request: &http::Request, stream: &mut &TcpStream) -> Result<Reply, Fail> {
        use std::io::Write;
        let (send, frames) = mpsc::sync_channel::<Arc<str>>(BACKLOG);
        {
            let _one = locked(&self.publishing);
            let first: Arc<str> = self.frame()?.into();
            let _ = send.try_send(first);
            let mut clients = locked(&self.clients);
            // close() sets the flag, then empties this list under the same lock: a stream is either ended by it or refused here.
            if self.closing.load(Ordering::SeqCst) { return Fail::at(503, "the to-do server is closing"); }
            clients.push(send);
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

/// One connection; however it ends (a panic too), it is counted out.
struct Guest { server: Arc<Server>, stream: Arc<TcpStream> }
impl Drop for Guest {
    fn drop(&mut self) {
        self.server.known(&self.stream);
        self.server.connections.fetch_sub(1, Ordering::SeqCst);
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
    fn change(&self, request: &mut http::Request, stream: &mut &TcpStream, path: &str) -> Result<Reply, Fail> {
        let body = match request.body(stream) {
            Ok(Some(bytes)) => bytes,
            Ok(None) => return Fail::at(413, "body too large"),
            Err(http::Bad::Closed) => return Fail::at(400, "request aborted"),
            Err(http::Bad::Status(status)) => return Fail::at(status, "invalid request body"),
        };
        let Some(body @ Json::Obj(_)) = json::parse(&String::from_utf8_lossy(&body)) else { return Fail::at(400, "invalid JSON object") };
        if request.method != "POST" { return Ok(Reply::Error(405, "method not allowed".into())); }
        let list = &self.list;
        let (id, version) = (body.get("id").and_then(Json::text), body.get("version").and_then(Json::text));
        let (id, version) = (id.as_deref(), version.as_deref());
        let mut launch = None;
        match path {
            "/api/exec" => {
                let result = self.run_item(id, version, body.get("path").and_then(Json::text).as_deref())?;
                return Ok(self.stored(|out| { out.push_str(",\"exec\":"); result.write(out); }));
            }
            "/api/items" => core::add(list, &line(body.get("text"), "text", usize::MAX)?)?,
            "/api/item" => match body.get("op").and_then(Json::text).as_deref() {
                Some("edit") => core::edit(list, id, version, &line(body.get("title"), "title", usize::MAX)?)?,
                Some("move") => match body.get("delta") {
                    Some(Json::Num(delta)) if delta.abs() == 1.0 => core::move_by(list, id, version, *delta as i64)?,
                    _ => return Fail::at(400, "invalid delta"),
                },
                Some("done") => core::done(list, id, version)?,
                Some("undone") => core::undone(list, id, version)?,
                Some("delete") => core::remove(list, id, version)?,
                Some("reply") => core::reply(list, id, version, &line(body.get("text"), "reply", usize::MAX)?)?,
                Some("fix") => launch = Some(self.fix(id, version)?),
                _ => return Fail::at(400, "invalid operation"),
            },
            "/api/approve" => self.approve(&body, id, version)?,
            _ => return Ok(Reply::Error(404, "not found".into())),
        }
        Ok(self.stored(|out| if let Some(launch) = &launch { out.push_str(",\"launch\":"); json::quote(launch, out); }))
    }

    /// Records the fix request and starts the agent todo-agent.json names, if it names one.
    fn fix(&self, id: Option<&str>, version: Option<&str>) -> Result<String, Fail> {
        let file = &self.options.file;
        let (id, project) = core::request_fix(&self.list, id, version)?;
        let config = setting("SDLC_TODO_AGENT").unwrap_or_else(|| js::join(&js::dirname(file), &["todo-agent.json"]));
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
        // The request is recorded: a program that cannot start is the launch's result, not the request's.
        run::launch(&argv, &cwd).or_else(|error| Ok(format!("failed: {}", error.message.trim_start_matches("spawn "))))
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
            sync::sync(&self.list, &self.options.kit, &item.id)?;
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
        core::update(&self.list, id, version, &mut |model, at| {
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
        // The approval is recorded; a status refresh that fails now is done by the next sync.
        if let Err(error) = sync::sync(&self.list, kit, "") { eprintln!("to-do sync: {}", error.message); }
        Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    fn served(name: &str) -> (PathBuf, Handle) {
        let dir = std::env::temp_dir().join(format!("sdlc-todo-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut options = Options::for_kit(&dir, Path::new(""), "node", "en");
        (options.file, options.feed, options.search_path) = (dir.join("todo.md").to_string_lossy().into(), dir.join("feed.json").to_string_lossy().into(), Some(String::new()));
        (dir, start(options).unwrap())
    }
    fn ask(handle: &Handle, method: &str, path: &str, more: &str) -> TcpStream {
        let Session { port, token } = handle.session();
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(stream, "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nOrigin: http://127.0.0.1:{port}\r\nContent-Type: application/json\r\nX-Todo-Token: {token}\r\n{more}").unwrap();
        stream
    }
    fn status(mut stream: TcpStream) -> String { let mut text = String::new(); let _ = stream.read_to_string(&mut text); text.chars().skip(9).take(3).collect() }

    #[test]
    fn a_post_still_sending_its_body_writes_nothing_after_close() {
        let (dir, handle) = served("late");
        let mut late = ask(&handle, "POST", "/api/items", "Content-Length: 15\r\n\r\n{\"text\"");
        std::thread::sleep(Duration::from_millis(300));
        handle.close();
        // The first sync may have written the empty list; nothing changes it after close.
        let before = std::fs::read(dir.join("todo.md")).ok();
        late.write_all(b":\"late\"}").unwrap();
        assert_eq!(status(late), "503");
        assert_eq!(std::fs::read(dir.join("todo.md")).ok(), before);
        assert!(!dir.join("todo.md.lock").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_stream_still_building_its_first_frame_is_refused_when_the_server_closes() {
        let (dir, handle) = served("late-stream");
        let building = locked(&handle.server.publishing);
        let stream = ask(&handle, "GET", &format!("/events?t={}", handle.session().token), "\r\n");
        std::thread::sleep(Duration::from_millis(300));
        handle.close();
        drop(building);
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        assert_eq!(status(stream), "503");
        assert!(locked(&handle.server.clients).is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_answer_to_a_stored_change_is_success_when_the_list_cannot_be_read_back() {
        let (dir, handle) = served("read-back");
        let _ = handle.server.synced();
        std::fs::remove_file(dir.join("todo.md")).unwrap();
        std::fs::create_dir(dir.join("todo.md")).unwrap();
        assert!(handle.server.payload().is_err());
        let Reply::Json(text) = handle.server.stored(|out| out.push_str(",\"launch\":\"queued\"")) else { panic!("an error") };
        let answer = json::parse(&text).unwrap();
        assert!(answer.get("items").is_none() && answer.get("launch") == Some(&Json::str("queued")));
        handle.close();
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_body_is_bounded_however_it_is_framed() {
        let (dir, handle) = served("frames");
        let chunked = "Transfer-Encoding: chunked\r\n\r\n";
        assert_eq!(status(ask(&handle, "POST", "/api/items", &format!("{chunked}5\r\n{{\"tex\r\n9;x=1\r\nt\":\"ok\"}}\r\n0\r\nA: b\r\n\r\n"))), "200");
        let mut endless = ask(&handle, "POST", "/api/items", &format!("{chunked}2\r\n{{}}\r\n0\r\n"));
        for _ in 0..4000 { if endless.write_all(b"X-Trailer: aaaaaaaaaaaaaaaa\r\n").is_err() { break; } }
        assert!(matches!(status(endless).as_str(), "431" | ""));
        std::fs::remove_dir_all(dir).unwrap();
        handle.close();
    }

    #[test]
    fn a_panic_under_every_lock_leaves_a_working_server() {
        let (dir, handle) = served("panic-locks");
        let server = handle.server.clone();
        let _ = std::thread::spawn(move || {
            let _all = (locked(&server.publishing), locked(&server.clients), locked(&server.feed), locked(&server.syncing), locked(&server.strangers));
            panic!("on purpose");
        }).join();
        for path in ["/api/live", "/api/items", "/api/feed"] { assert_eq!(status(ask(&handle, "GET", path, "\r\n")), "200", "{path}"); }
        let mut stream = ask(&handle, "GET", &format!("/events?t={}", handle.session().token), "\r\n");
        core::add(&handle.server.list, "seen").unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let (mut text, mut buffer) = (String::new(), [0; 4096]);
        while !text.contains("seen") { let n = stream.read(&mut buffer).unwrap(); assert!(n > 0); text.push_str(&String::from_utf8_lossy(&buffer[..n])); }
        handle.close();
        std::fs::remove_dir_all(dir).unwrap();
    }
}
