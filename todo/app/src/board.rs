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
use std::time::Duration;
use tauri::webview::NewWindowResponse;
use tauri::{AppHandle, Manager, Monitor, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent};

pub const LABEL: &str = "board";

/// The page's view to show.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum View { Board, List }

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
  const ask = (name, args) => window.__TAURI_INTERNALS__.invoke(name, args);
  Object.defineProperty(window, 'todoApp', { value: Object.freeze({
    ticket: (url, follow) => ask('ticket', { url, follow }),
    state: () => ask('app_state'),
    saveMemo: (id, text) => ask('save_memo', { id, text }),
    saveView: (size, font) => ask('save_view', { size, font }),
    openTerminal: id => ask('open_terminal', { id })
  }) });
})()"#;

/// Whether the page holds something that closing would lose. A page without the question (an older one) is kept.
const BUSY: &str = "(() => { const page = globalThis.todoPage; return page ? (typeof page.busy === 'function' ? page.busy() : true) : false; })()";

/// The board's address opening on `view`.
fn address(session: &Session, view: View) -> Result<Url, String> {
    let start = if view == View::List { "&view=list" } else { "" };
    Url::parse(&format!("{}{start}", session.board_url())).map_err(|_| "the server's address is not one".into())
}

fn view_script(view: View) -> &'static str {
    match view {
        View::Board => "window.dispatchEvent(new CustomEvent('todo-view', { detail: 'board' }))",
        View::List => "window.dispatchEvent(new CustomEvent('todo-view', { detail: 'list' }))",
    }
}

/// Brings the board forward on `view`; while no server answers, the shell's own page says so.
pub fn show(app: &AppHandle, view: View) {
    let _one = lock(&WINDOW);
    let shell = app.state::<Shell>();
    let window = app.get_webview_window(LABEL);
    let target = lock(&shell.shared).board_to_open(true, window.is_some()).map(|(session, _)| session);
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
    // A page already there switches; one that loads now opens on the view its address names.
    let _ = window.eval(view_script(view));
}

/// After a server came or was replaced: an open window loads the new address in place, hidden or not, without coming
/// forward. `open` is the launch's own first showing.
pub fn follow_server(app: &AppHandle, open: bool) {
    if open { return show(app, View::Board); }
    let _one = lock(&WINDOW);
    let Some(window) = app.get_webview_window(LABEL) else { return };
    let next = lock(&app.state::<Shell>().shared).board_to_open(false, true);
    if let Some((session, _)) = next { load(app, &window, &session, View::Board); }
}

/// Tells the shell's own page how things stand; does nothing while the board's page is loaded.
pub fn offline(app: &AppHandle) {
    let Some(window) = app.get_webview_window(LABEL) else { return };
    if !window.url().is_ok_and(|url| links::within(url.as_str(), SHELL_ORIGIN)) { return; }
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
    // A page that did not come up (the server went away meanwhile) is loaded again.
    let there = window.url().is_ok_and(|url| links::within(url.as_str(), &session.origin()));
    if there && lock(&shell.shared).loaded.as_ref() == Some(session) { return; }
    let Ok(url) = address(session, view) else { return };
    allow(app, session);
    match window.navigate(url) {
        Ok(()) => lock(&shell.shared).loaded = Some(session.clone()),
        Err(_) => eprintln!("sdlc-todo: the board window could not load the server's page"),
    }
}

fn make(app: &AppHandle, session: Option<&Session>, view: View) -> Result<WebviewWindow, String> {
    let shell = app.state::<Shell>();
    let page = match session {
        Some(session) => { allow(app, session); WebviewUrl::External(address(session, view)?) }
        None => WebviewUrl::App(format!("index.html#{}", offline_words(app)).into()),
    };
    lock(&shell.shared).loaded = session.cloned();
    let (nav, popup) = (app.clone(), app.clone());
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
        .build();
    let window = match built {
        Ok(window) => window,
        Err(error) => { lock(&shell.shared).loaded = None; return Err(error.to_string()); }
    };
    place(&shell, &window);
    let events = app.clone();
    window.on_window_event(move |event| match event {
        WindowEvent::CloseRequested { api, .. } => { api.prevent_close(); close(&events); }
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
    let app = app.clone();
    let _ = window.eval_with_callback(BUSY, move |answer| {
        if answer.trim() != "false" { return; }
        later(&app, |app| {
            let _one = lock(&WINDOW);
            let Some(window) = app.get_webview_window(LABEL) else { return };
            // Asked for again meanwhile: keep it.
            if window.is_visible().unwrap_or(true) { return; }
            if window.destroy().is_ok() {
                lock(&app.state::<Shell>().shared).loaded = None;
                // The label is free once the event loop has let the window go.
                for _ in 0..100 {
                    if app.get_webview_window(LABEL).is_none() { break; }
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
        });
    });
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
