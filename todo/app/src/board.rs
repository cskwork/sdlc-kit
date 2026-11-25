//! The board window: the server's web page in the system webview. It is made when first asked for, and closing it
//! frees its webview unless the page holds something unsent.
//!
//! Every function that makes or changes the window runs off the main thread (`later`): on Windows, making a webview
//! inside an event handler of the main thread deadlocks.
use crate::i18n::t;
use crate::links::{self, Navigation};
use crate::window::{board_frame, Frame, Latest, WindowState, BOARD_MIN};
use crate::{lock, server::Session, Conn, Shell};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::webview::{NewWindowResponse, PageLoadEvent};
use tauri::{AppHandle, Manager, Monitor, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent};

pub const LABEL: &str = "board";

/// The page's view to show.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum View { Board, List }

impl View {
    pub fn name(self) -> &'static str { if self == View::List { "list" } else { "board" } }
}

/// The view last picked on the tray; a page the shell loads by itself opens on it.
static VIEW: Mutex<View> = Mutex::new(View::Board);
/// One change to the window at a time.
static WINDOW: Mutex<()> = Mutex::new(());
static MOVES: Latest = Latest::new();

/// Runs `job` off the main thread.
pub fn later(app: &AppHandle, job: impl FnOnce(&AppHandle) + Send + 'static) {
    let app = app.clone();
    std::thread::spawn(move || job(&app));
}

/// The origin of the shell's own pages, as the webview shows it.
pub const SHELL_ORIGIN: &str = if cfg!(any(windows, target_os = "android")) { "http://tauri.localhost" } else { "tauri://localhost" };

/// What the page finds as `todoApp`: the few things it may ask of the shell (bridge.rs). The page knows nothing else of
/// the shell, and the shell answers only the board's own origin.
const BRIDGE: &str = r#"(() => {
  // The token the page was opened with proves to the shell that it is that page.
  const proof = new URLSearchParams(location.hash.slice(1)).get('t') || '';
  const ask = (name, args) => window.__TAURI_INTERNALS__.invoke(name, { proof, ...args });
  let view = '';
  addEventListener('todo-view', event => { view = event.detail; });
  Object.defineProperty(window, 'todoApp', { value: Object.freeze({
    ticket: (url, follow) => ask('ticket', { url, follow }),
    state: () => ask('app_state'),
    saveMemo: (id, text) => ask('save_memo', { id, text }),
    saveView: (size, font) => ask('save_view', { size, font }),
    openTerminal: (id, command) => ask('open_terminal', { id, command }),
    unsent: unsent => ask('unsent', { unsent }),
    quit: () => ask('quit'),
    // The view last picked on the tray, also before the page could listen.
    view: () => view
  }) });
})()"#;

/// What the page holds that another page could take up (app.js), and how long the person has not typed.
const CARRY: &str = "(() => { const page = globalThis.todoPage; return page && page.carry ? JSON.stringify(page.carry()) : ''; })()";
/// Asks the person in the page whether to quit; true when the page did ask.
const ASK_QUIT: &str = "!!(globalThis.todoPage && todoPage.askQuit && todoPage.askQuit())";
/// How long a page that is being typed in is waited for before it is replaced, and what counts as still typing.
const TYPING: (Duration, f64) = (Duration::from_secs(4), 1200.0);

/// Whether the page holds something that closing would lose. A page without the question (an older one) is kept.
const BUSY: &str = "(() => { const page = globalThis.todoPage; return page ? (typeof page.busy === 'function' ? page.busy() : true) : false; })()";

/// The board's address opening on `view`.
fn address(session: &Session, view: View) -> Result<Url, String> {
    let start = if view == View::List { "&view=list" } else { "" };
    Url::parse(&format!("{}{start}", session.board_url())).map_err(|_| "the server's address is not one".into())
}

fn view_script(view: View) -> String { format!("window.dispatchEvent(new CustomEvent('todo-view', {{ detail: '{}' }}))", view.name()) }

/// Runs `script` in the page and waits for its answer (JSON). Off the main thread only: the answer comes through it.
fn ask_page(window: &WebviewWindow, script: &str, limit: Duration) -> Option<serde_json::Value> {
    let (send, answer) = std::sync::mpsc::channel();
    window.eval_with_callback(script, move |text| { let _ = send.send(text); }).ok()?;
    serde_json::from_str(&answer.recv_timeout(limit).ok()?).ok()
}

/// A page's answer to CARRY.
#[derive(Debug, PartialEq)]
enum Held {
    /// What it holds, and the milliseconds since the last key.
    Words(serde_json::Value, f64),
    /// A page that keeps nothing (an older one, or none of ours).
    Nothing,
    /// No answer, or one that is not one: what it holds is not known.
    Unknown,
}

/// Whether a CARRY answer holds anything a person typed (not only a view, a selection or a cursor).
fn holds_words(held: &serde_json::Value) -> bool {
    fn typed(value: &serde_json::Value) -> bool {
        match value {
            serde_json::Value::String(text) => !text.trim().is_empty(),
            serde_json::Value::Array(list) => list.iter().any(typed),
            // Only what was written counts: not the item's id, the suggestion it started from or its version.
            serde_json::Value::Object(map) => map.iter().any(|(key, value)| !["id", "seed", "replyVersion"].contains(&key.as_str()) && typed(value)),
            _ => false,
        }
    }
    // Drafts are [id, { reply, words, … }] pairs.
    let drafts = |part: &serde_json::Value| part.get("drafts").and_then(serde_json::Value::as_array)
        .is_some_and(|list| list.iter().any(|pair| pair.get(1).is_some_and(typed)));
    ["list", "board", "memos"].iter().any(|part| match (*part, held.get(part)) {
        ("list", Some(list)) => drafts(list) || ["add", "edits", "edit", "lost"].iter().any(|key| list.get(key).is_some_and(typed)),
        ("board", Some(board)) => drafts(board) || board.get("note").is_some_and(typed),
        ("memos", Some(memos)) => memos.as_object().is_some_and(|memos| !memos.is_empty()),
        _ => false,
    })
}

fn carried(answer: Option<serde_json::Value>) -> Held {
    let Some(text) = answer.as_ref().and_then(serde_json::Value::as_str) else { return Held::Unknown };
    if text.is_empty() { return Held::Nothing; }
    match serde_json::from_str::<serde_json::Value>(text) {
        Ok(held) if held.is_object() => {
            let idle = held.get("idle").and_then(serde_json::Value::as_f64).unwrap_or(f64::MAX);
            Held::Words(held, idle)
        }
        _ => Held::Unknown,
    }
}

/// Keeps what the page holds for the one that replaces it. Nothing typed is lost: a page in use is waited for briefly,
/// and a page that could not be read is not replaced (false); the next change of the list tries again.
fn keep(app: &AppHandle, window: &WebviewWindow) -> bool {
    let shell = app.state::<Shell>();
    // Only a page of the server this window was sent to; the shell's own holds nothing.
    let ours = { let shared = lock(&shell.shared); shared.loaded.as_ref().is_some_and(|session| shared.page.as_deref() == Some(session.origin().as_str())) };
    if !ours { return true; }
    let started = Instant::now();
    let mut latest = Held::Nothing;
    loop {
        match carried(ask_page(window, CARRY, Duration::from_secs(2))) {
            Held::Unknown => return false,
            Held::Nothing => break,
            Held::Words(held, idle) => {
                latest = Held::Words(held, idle);
                if idle >= TYPING.1 || started.elapsed() >= TYPING.0 { break; }
            }
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    settle(&mut lock(&shell.carried), latest);
    true
}

/// What goes on to the next page: only the last answer of this replacement, so words deleted meanwhile (Esc) stay gone.
/// Words carried from earlier pages are in that answer once the page took them up; until then they stay as they are, and
/// an answer without words never replaces or holds anything.
fn settle(carried: &mut Option<serde_json::Value>, latest: Held) {
    if let Held::Words(held, _) = latest { if holds_words(&held) { *carried = Some(held); } }
}

/// The view last picked on the tray.
pub fn current_view() -> View { *lock(&VIEW) }

/// Asks in the page before quitting. False when there is no page to ask.
pub fn ask_quit(app: &AppHandle) -> bool {
    let _one = lock(&WINDOW);
    let Some(window) = app.get_webview_window(LABEL) else { return false };
    let _ = window.unminimize();
    let _ = window.show();
    let _ = window.set_focus();
    ask_page(&window, ASK_QUIT, Duration::from_secs(3)) == Some(true.into())
}

/// Brings the board forward on `view`; while no server answers, the shell's own page says so.
pub fn show(app: &AppHandle, view: View) {
    let _one = lock(&WINDOW);
    *lock(&VIEW) = view;
    let shell = app.state::<Shell>();
    let window = app.get_webview_window(LABEL);
    let target = lock(&shell.shared).board_to_open(true, window.is_some()).map(|(session, _)| session);
    let there = window.is_some() && target.as_ref().is_some_and(|session| !lock(&shell.shared).must_load(session));
    let window = match (window, &target) {
        (Some(window), Some(session)) => { load(app, &window, session, view); window }
        // The page that was loaded shows by itself that its server is away; its drafts stay.
        (Some(window), None) => { offline(app); window }
        (None, _) => match make(app, target.as_ref(), view) {
            Ok(window) => window,
            Err(error) => {
                eprintln!("sdlc-todo: the board window could not start ({error}); opening the board in the browser");
                if let Some(session) = &target { crate::system::open_url(&session.board_url()); }
                return;
            }
        },
    };
    let _ = window.unminimize();
    let _ = window.show();
    let _ = window.set_focus();
    // A page already there switches; one that loads now opens on the view its address names, and one that was still
    // loading asks for this pick when it is up.
    if there { *lock(&shell.picked) = Some(view); }
    let _ = window.eval(view_script(view));
}

/// After a server came or was replaced: an open window loads the new address in place, hidden or not, without coming
/// forward. `open` is the launch's own first showing.
pub fn follow_server(app: &AppHandle, open: bool) {
    // The launch's own showing keeps a view picked on the tray while the server was away.
    let view = *lock(&VIEW);
    if open { return show(app, view); }
    let _one = lock(&WINDOW);
    let Some(window) = app.get_webview_window(LABEL) else { return };
    let next = lock(&app.state::<Shell>().shared).board_to_open(false, true);
    if let Some((session, _)) = next { load(app, &window, &session, *lock(&VIEW)); }
}

/// Tells the shell's own page how things stand; does nothing while the board's page is loaded.
pub fn offline(app: &AppHandle) {
    let Some(window) = app.get_webview_window(LABEL) else { return };
    if lock(&app.state::<Shell>().shared).page.as_deref() != Some(SHELL_ORIGIN) { return; }
    let words = serde_json::Value::from(offline_words(app)).to_string();
    let _ = window.eval(format!("location.replace('#' + {words})"));
}

/// The words of the shell's own page, as its address's fragment.
fn offline_words(app: &AppHandle) -> String {
    let shell = app.state::<Shell>();
    let (title, reason, hint) = match &lock(&shell.shared).conn {
        Conn::Offline(reason) => ("offline", reason.clone(), "offline.hint"),
        _ => ("connecting", String::new(), ""),
    };
    let mut url = Url::parse("tauri://localhost/").expect("a fixed address");
    url.query_pairs_mut().append_pair("lang", shell.lang().code()).append_pair("title", t(shell.lang(), title))
        .append_pair("reason", &reason).append_pair("hint", t(shell.lang(), hint));
    url.query().unwrap_or("").to_string()
}

/// Lets the server's origin, and no other, use the bridge, once per origin.
fn allow(app: &AppHandle, session: &Session) {
    let shell = app.state::<Shell>();
    if !lock(&shell.allowed).insert(session.port) { return; }
    let capability = crate::bridge::COMMANDS.iter().fold(
        tauri::ipc::CapabilityBuilder::new(format!("board-{}", session.port)).local(false).remote(session.origin()).window(LABEL),
        |capability, command| capability.permission(format!("allow-{}", command.replace('_', "-"))));
    if let Err(error) = app.add_capability(capability) { eprintln!("sdlc-todo: the board may not ask the app for anything: {error}"); }
}

fn load(app: &AppHandle, window: &WebviewWindow, session: &Session, view: View) {
    let shell = app.state::<Shell>();
    if !lock(&shell.shared).must_load(session) { return; }
    let Ok(url) = address(session, view) else { return };
    if !keep(app, window) { return eprintln!("sdlc-todo: the page did not say what it holds; it stays until it does"); }
    *lock(&shell.picked) = None;
    allow(app, session);
    match window.navigate(url) {
        Ok(()) => asked(&shell, Some(session)),
        Err(_) => eprintln!("sdlc-todo: the board window could not load the server's page"),
    }
}

fn asked(shell: &Shell, session: Option<&Session>) {
    let mut shared = lock(&shell.shared);
    (shared.loaded, shared.asked) = (session.cloned(), Instant::now());
}

fn make(app: &AppHandle, session: Option<&Session>, view: View) -> Result<WebviewWindow, String> {
    let shell = app.state::<Shell>();
    let page = match session {
        Some(session) => { allow(app, session); WebviewUrl::External(address(session, view)?) }
        None => WebviewUrl::App(format!("index.html#{}", offline_words(app)).into()),
    };
    asked(&shell, session);
    lock(&shell.shared).page = None;
    *lock(&shell.picked) = None;
    let (nav, popup, pages) = (app.clone(), app.clone(), app.clone());
    let built = WebviewWindowBuilder::new(app, LABEL, page)
        .title(t(shell.lang(), "title"))
        .visible(false).focused(false)
        .inner_size(1000.0, 700.0).min_inner_size(BOARD_MIN.0, BOARD_MIN.1)
        .initialization_script(BRIDGE)
        // The page's own rem-based size (bridge.rs) is the one text size; the webview's zoom keys stay off.
        .zoom_hotkeys_enabled(false)
        .devtools(cfg!(debug_assertions))
        .on_navigation(move |url| navigate(&nav, url.as_str()))
        .on_new_window(move |url, _| { hand_off(&popup, url.as_str()); NewWindowResponse::Deny })
        .on_document_title_changed(|window, title| { if !title.is_empty() { let _ = window.set_title(&title); } })
        .on_page_load(move |_, load| {
            if load.event() != PageLoadEvent::Finished { return; }
            let url = load.url();
            let origin = match (url.host_str(), url.port()) {
                (Some(host), Some(port)) => format!("{}://{host}:{port}", url.scheme()),
                (Some(host), None) => format!("{}://{host}", url.scheme()),
                _ => return,
            };
            lock(&pages.state::<Shell>().shared).page = Some(origin);
        })
        .build();
    let window = match built {
        Ok(window) => window,
        Err(error) => { asked(&shell, None); return Err(error.to_string()); }
    };
    place(&shell, &window);
    let events = app.clone();
    window.on_window_event(move |event| match event {
        WindowEvent::CloseRequested { api, .. } => {
            api.prevent_close();
            // Without a tray nothing would bring a hidden window back.
            if events.state::<Shell>().no_tray.load(std::sync::atomic::Ordering::SeqCst) { crate::quit::request(&events) } else { close(&events) }
        }
        WindowEvent::Moved(_) | WindowEvent::Resized(_) => save_when_still(&events),
        _ => {}
    });
    Ok(window)
}

fn navigate(app: &AppHandle, to: &str) -> bool {
    let board = lock(&app.state::<Shell>().shared).session.as_ref().map(Session::origin).unwrap_or_default();
    match links::navigation(to, &board, SHELL_ORIGIN) {
        Navigation::Stay => return true,
        Navigation::HandOff => hand_off(app, to),
        Navigation::Refuse => eprintln!("sdlc-todo: the board may not go to {}", links::loggable(to)),
    }
    false
}

/// A link the board does not show itself: a web page to the ticket window, mail to the mail app; anything else is
/// refused, since the system's handler would launch it.
fn hand_off(app: &AppHandle, url: &str) {
    if links::ticket(url).is_ok() { return open_ticket(app, url, false); }
    if links::system_may_open(url) { return crate::system::open_url(url); }
    eprintln!("sdlc-todo: refused to open {}: only http(s) and mailto: links leave the board", links::loggable(url));
}

/// Shows a ticket: on macOS in the person's Chrome beside the board, elsewhere in the default browser. Following the
/// selection moves only a ticket window that is open, which a default browser does not offer.
pub fn open_ticket(app: &AppHandle, url: &str, follow: bool) {
    #[cfg(target_os = "macos")]
    {
        let screen = app.get_webview_window(LABEL).and_then(|window| window.current_monitor().ok().flatten())
            .or_else(|| app.primary_monitor().ok().flatten()).map(|monitor| free_area(&monitor));
        crate::ticket::open(url.to_string(), follow, screen.unwrap_or(Frame { x: 0.0, y: 0.0, width: 1440.0, height: 900.0 }));
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        if !follow { crate::system::open_url(url); }
    }
}

// ---------- closing ----------

/// Hides the window, then frees its webview (the largest part of the app's memory) unless the page holds a draft or
/// a request; then it stays hidden and comes back as it was.
fn close(app: &AppHandle) {
    save_place(app);
    let Some(window) = app.get_webview_window(LABEL) else { return };
    let _ = window.hide();
    // No page came up: there is nothing to ask, and nothing to lose.
    if lock(&app.state::<Shell>().shared).page.is_none() { return later(app, free); }
    let app = app.clone();
    let _ = window.eval_with_callback(BUSY, move |answer| if answer.trim() == "false" { later(&app, free); });
}

/// Frees a hidden window's webview.
fn free(app: &AppHandle) {
    let _one = lock(&WINDOW);
    let Some(window) = app.get_webview_window(LABEL) else { return };
    // Asked for again meanwhile: keep it.
    if window.is_visible().unwrap_or(true) { return; }
    // Words on their way to a page that has not taken them up yet wait for it.
    if lock(&app.state::<Shell>().carried).is_some() { return; }
    if window.destroy().is_err() { return; }
    {
        let shell = app.state::<Shell>();
        asked(&shell, None);
        let mut shared = lock(&shell.shared);
        (shared.page, shared.unsent) = (None, false);
    }
    // The label is free once the event loop has let the window go.
    for _ in 0..100 {
        if app.get_webview_window(LABEL).is_none() { break; }
        std::thread::sleep(Duration::from_millis(10));
    }
}

// ---------- place ----------

/// `Frame` counts points on macOS and pixels elsewhere: this is what a pixel count there is divided by.
fn unit(scale: f64) -> f64 { if cfg!(target_os = "macos") { scale } else { 1.0 } }

fn free_area(monitor: &Monitor) -> Frame {
    let (area, unit) = (monitor.work_area(), unit(monitor.scale_factor()));
    Frame { x: f64::from(area.position.x) / unit, y: f64::from(area.position.y) / unit, width: f64::from(area.size.width) / unit, height: f64::from(area.size.height) / unit }
}

/// Puts a new window at its saved place, or beside the ticket window.
fn place(shell: &Shell, window: &WebviewWindow) {
    let primary = window.primary_monitor().ok().flatten();
    let mut screens: Vec<Frame> = primary.iter().map(free_area).collect();
    for monitor in window.available_monitors().unwrap_or_default() {
        let area = free_area(&monitor);
        if !screens.contains(&area) { screens.push(area); }
    }
    let main_height = primary.as_ref().map(|m| f64::from(m.size().height) / unit(m.scale_factor())).unwrap_or(900.0);
    let scale = window.scale_factor().unwrap_or(1.0);
    let least = if cfg!(target_os = "macos") { 1.0 } else { scale };
    let saved = WindowState::load(&shell.window_file).place(main_height);
    let frame = board_frame(saved, &screens, (BOARD_MIN.0 * least, BOARD_MIN.1 * least));
    // The frame includes the title bar and edges; the window is sized by its content.
    let edges = match (window.outer_size(), window.inner_size()) {
        (Ok(outer), Ok(inner)) => (f64::from(outer.width.saturating_sub(inner.width)) / unit(scale), f64::from(outer.height.saturating_sub(inner.height)) / unit(scale)),
        _ => (0.0, 0.0),
    };
    let (width, height) = (frame.width - edges.0, frame.height - edges.1);
    if cfg!(target_os = "macos") {
        let _ = window.set_size(tauri::LogicalSize::new(width, height));
        let _ = window.set_position(tauri::LogicalPosition::new(frame.x, frame.y));
    } else {
        let _ = window.set_position(tauri::PhysicalPosition::new(frame.x.round() as i32, frame.y.round() as i32));
        let _ = window.set_size(tauri::PhysicalSize::new(width.round().max(1.0) as u32, height.round().max(1.0) as u32));
    }
}

/// A drag sends many moves; the place is kept once the window has stood still for half a second.
fn save_when_still(app: &AppHandle) {
    let moved = MOVES.take();
    later(app, move |app| {
        std::thread::sleep(Duration::from_millis(500));
        if MOVES.is_newest(moved) { save_place(app); }
    });
}

/// Keeps the window's place now; a hidden, minimised or full-screen window has none to keep.
pub fn save_place(app: &AppHandle) {
    let Some(window) = app.get_webview_window(LABEL) else { return };
    if !window.is_visible().unwrap_or(false) || window.is_minimized().unwrap_or(false) || window.is_fullscreen().unwrap_or(false) { return; }
    let (Ok(position), Ok(size), Ok(scale)) = (window.outer_position(), window.outer_size(), window.scale_factor()) else { return };
    let unit = unit(scale);
    let frame = Frame { x: f64::from(position.x) / unit, y: f64::from(position.y) / unit, width: f64::from(size.width) / unit, height: f64::from(size.height) / unit };
    if let Err(error) = WindowState::of(frame).save(&app.state::<Shell>().window_file) { eprintln!("sdlc-todo: {error}"); }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_the_last_answer_of_a_replacement_goes_on() {
        let words = |text: &str| json!({ "list": { "add": text } });
        // The page said "draft", then the person pressed Esc: the last answer has nothing, so nothing goes on.
        let mut carried = None;
        let mut latest = Held::Nothing;
        for answer in [words("draft"), words("")] { latest = Held::Words(answer, 0.0); }
        settle(&mut carried, latest);
        assert_eq!(carried, None);
        // Words carried from an earlier page and not taken up yet stay when this page holds none.
        let mut carried = Some(words("earlier"));
        settle(&mut carried, Held::Words(words(""), 0.0));
        settle(&mut carried, Held::Nothing);
        assert_eq!(carried, Some(words("earlier")));
        settle(&mut carried, Held::Words(words("now"), 0.0));
        assert_eq!(carried, Some(words("now")));
    }

    #[test]
    fn what_a_page_holds_is_read_from_its_answer() {
        let answer = serde_json::Value::from(json!({ "idle": 40, "list": { "add": "한글 \"draft\"" } }).to_string());
        let Held::Words(held, idle) = carried(Some(answer)) else { panic!("words") };
        assert_eq!((held["list"]["add"].as_str(), idle), (Some("한글 \"draft\""), 40.0));
        // A page that never counted typing is not waited for.
        assert_eq!(carried(Some(json!("{}"))), Held::Words(json!({}), f64::MAX));
        // A page without anything to keep says so; silence or nonsense is not "nothing", and the page is not replaced.
        assert_eq!(carried(Some(json!(""))), Held::Nothing);
        // An empty page holds no words; a view, selection or cursor alone is not worth keeping the app for.
        assert!(!holds_words(&json!({ "idle": 5, "list": { "drafts": [], "add": "", "edits": [], "open": "x" }, "board": { "drafts": [], "note": null, "selected": "k", "view": "list" }, "memos": {}, "focus": { "id": "a", "at": 1 } })));
        assert!(!holds_words(&json!({ "list": { "drafts": [["a", { "reply": " ", "words": "", "seed": "suggested" }]] } })));
        for held in [json!({ "list": { "add": "x" } }), json!({ "list": { "drafts": [["a", { "reply": "", "words": "note" }]] } }), json!({ "list": { "edits": [{ "id": "a", "text": "n" }] } }),
            json!({ "list": { "lost": ["w"] } }), json!({ "board": { "note": { "id": "a", "text": "t" } } }), json!({ "memos": { "a": "" } })] {
            assert!(holds_words(&held), "{held}");
        }
        for answer in [None, Some(json!(null)), Some(json!("[]")), Some(json!("{ broken")), Some(json!(true))] { assert_eq!(carried(answer.clone()), Held::Unknown, "{answer:?}"); }
    }
}
