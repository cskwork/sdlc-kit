//! The board window: the web board in a native window of the app, drawn by the system webview (WKWebView through
//! wry). Tickets it opens go to the person's Chrome, docked at the screen's left edge (see ticket.rs).
//!
//! Event loop: eframe 0.31 owns the winit loop and offers no hook to add windows of our own, and tao would want to
//! own NSApplication too. On macOS every window of a process shares the one NSApplication run loop, so the board
//! window is a plain AppKit NSWindow made on the main thread, with wry attached through a raw window handle.
//! winit keeps running the loop and the egui list window as before. Elsewhere the board opens in Chrome or the
//! default browser, as it did before (see `main.rs`).
//!
//! The pure parts (window frames, which window a URL belongs to, the saved-window file) build and test everywhere.
// Only the macOS board window uses these yet; the tests run them everywhere.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]
use serde::{Deserialize, Serialize};
use std::path::Path;

/// A window frame in AppKit screen points: origin at the bottom left of the main screen, y growing upwards.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Frame {
    fn overlap(&self, other: &Frame) -> (f64, f64) {
        let width = (self.x + self.width).min(other.x + other.width) - self.x.max(other.x);
        let height = (self.y + self.height).min(other.y + other.height) - self.y.max(other.y);
        (width.max(0.0), height.max(0.0))
    }
}

/// The smallest board window: the board's narrow layout still fits.
pub const BOARD_MIN: (f64, f64) = (640.0, 480.0);

/// Part of the screen the ticket window takes at its left edge, as board.js asks of its popup (v3.3.4).
const TICKET_SHARE: f64 = 0.45;

/// The ticket window: the left edge of the screen's visible area, 45% of its width, its full height.
pub fn ticket_frame(screen: Frame) -> Frame {
    Frame { x: screen.x, y: screen.y, width: (screen.width * TICKET_SHARE).round(), height: screen.height }
}

/// The board window: the saved frame, held inside the visible area of the screen it overlaps most (no bigger than
/// that area, its title bar below the top edge), while it is big enough and still touches a screen (a display may
/// have gone since); otherwise the rest of the main screen beside the ticket window. `screens` are the visible
/// frames, the main screen first.
pub fn board_frame(saved: Option<Frame>, screens: &[Frame]) -> Frame {
    let sound = |frame: &Frame| [frame.x, frame.y, frame.width, frame.height].iter().all(|v| v.is_finite())
        && frame.width >= BOARD_MIN.0 && frame.height >= BOARD_MIN.1;
    let area = |frame: &Frame, screen: &Frame| { let (w, h) = frame.overlap(screen); w * h };
    if let Some(frame) = saved.filter(sound) {
        let best = screens.iter().filter(|screen| area(&frame, screen) > 0.0)
            .max_by(|a, b| area(&frame, a).total_cmp(&area(&frame, b)));
        if let Some(screen) = best { return clamp(frame, *screen); }
    }
    let main = screens.first().copied().unwrap_or(Frame { x: 0.0, y: 0.0, width: 1440.0, height: 900.0 });
    let ticket = ticket_frame(main);
    let width = (main.width - ticket.width).max(BOARD_MIN.0.min(main.width));
    Frame { x: main.x + main.width - width, y: main.y, width, height: main.height }
}

/// `frame` moved and shrunk to fit inside `screen` (AppKit: its top edge, where the title bar is, at most the top).
fn clamp(frame: Frame, screen: Frame) -> Frame {
    let (width, height) = (frame.width.min(screen.width), frame.height.min(screen.height));
    Frame {
        x: frame.x.clamp(screen.x, screen.x + screen.width - width),
        y: frame.y.clamp(screen.y, screen.y + screen.height - height),
        width,
        height,
    }
}

/// Where a link from the board belongs.
#[derive(Debug, PartialEq)]
pub enum Target {
    /// The board's own server on this machine (127.0.0.1, localhost, ::1).
    Board,
    /// Any other http(s) page, such as a Jira ticket: the ticket window.
    External,
    /// Anything else (about:, mailto:, javascript:, file:, …).
    Other,
}

/// Whether a non-web link may go to the system's handler (`open`): only mail. Anything else (`file:` to an app,
/// `vscode:`, `x-apple.systempreferences:` …) would launch through LaunchServices, so it is refused.
pub fn system_may_open(url: &str) -> bool { url.trim_start().get(..7).is_some_and(|scheme| scheme.eq_ignore_ascii_case("mailto:")) }

pub fn classify(url: &str) -> Target {
    let url = url.trim();
    let scheme_end = url.find("://").unwrap_or(0);
    if !matches!(url[..scheme_end].to_ascii_lowercase().as_str(), "http" | "https") { return Target::Other; }
    let authority = url[scheme_end + 3..].split(['/', '?', '#', '\\']).next().unwrap_or("");
    // A user part (`127.0.0.1@evil.example`) does not name the host.
    let host_port = authority.rsplit('@').next().unwrap_or("");
    let host = match host_port.strip_prefix('[') {
        Some(rest) => rest.split(']').next().unwrap_or(""),
        None => host_port.split(':').next().unwrap_or(""),
    }.to_ascii_lowercase();
    match host.trim_end_matches('.') {
        "" => Target::Other,
        "127.0.0.1" | "localhost" | "::1" => Target::Board,
        _ => Target::External,
    }
}

/// The saved windows, in `todo-app-window.json` beside the app's `todo-app.json`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct WindowState {
    #[serde(default)]
    pub board: Option<Frame>,
}

impl WindowState {
    /// Only window places live here, nothing anyone wrote: a missing or broken file means the default places.
    pub fn load(file: &Path) -> WindowState {
        match std::fs::read_to_string(file) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_else(|error| {
                eprintln!("sdlc-todo: {}: {error}; using the default window place", file.display());
                WindowState::default()
            }),
            Err(_) => WindowState::default(),
        }
    }

    /// Written beside and renamed over, like the settings file, so a crash never leaves half a file.
    pub fn save(&self, file: &Path) -> Result<(), String> {
        let text = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        let mut name = file.as_os_str().to_owned();
        name.push(".tmp");
        let temp = std::path::PathBuf::from(name);
        std::fs::write(&temp, text).map_err(|e| format!("{}: {e}", temp.display()))?;
        std::fs::rename(&temp, file).map_err(|e| format!("{}: {e}", file.display()))
    }
}

/// What the board page asks of the app through `window.ipc.postMessage` (board.js, in the app's own window).
#[derive(Debug, PartialEq)]
pub enum Ask {
    /// The person opened a ticket (its button or **T**): show it in the Chrome ticket window and bring that forward,
    /// making the window again when it was closed.
    Open(String),
    /// The selection moved to another ticket: move an open ticket window to it, leaving it behind the board, and make
    /// none when there is none.
    Follow(String),
}

/// Numbers events so a delayed action can tell whether a newer one came since (the board's moves: only the last one
/// saves the place).
pub struct Latest(std::sync::atomic::AtomicU64);

impl Latest {
    pub const fn new() -> Latest { Latest(std::sync::atomic::AtomicU64::new(0)) }
    pub fn take(&self) -> u64 { self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1 }
    pub fn is_newest(&self, ticket: u64) -> bool { self.0.load(std::sync::atomic::Ordering::SeqCst) == ticket }
}

/// The longest message the board sends: a ticket address with room to spare.
const ASK_LIMIT: usize = 8 * 1024;

/// Reads one message from the page at `from` (the sending frame's address). Only the board's own page (`board`, its
/// `http://127.0.0.1:<port>` origin) is heard, and only `{"open": url}` or `{"follow": url}` with an http(s) address
/// off this machine.
pub fn ask(from: &str, board: &str, body: &str) -> Result<Ask, String> {
    if from != board && !from.starts_with(&format!("{board}/")) { return Err(format!("not from the board: {from}")); }
    if body.len() > ASK_LIMIT { return Err(format!("message of {} bytes, over {ASK_LIMIT}", body.len())); }
    let value: serde_json::Value = serde_json::from_str(body).map_err(|e| format!("not JSON: {e}"))?;
    let object = value.as_object().filter(|object| object.len() == 1).ok_or("not a one-field object")?;
    let (kind, url) = object.iter().next().expect("one field");
    let url = url.as_str().ok_or("the address is not a string")?.to_string();
    if classify(&url) != Target::External { return Err(format!("not a ticket address: {url}")); }
    match kind.as_str() {
        "open" => Ok(Ask::Open(url)),
        "follow" => Ok(Ask::Follow(url)),
        other => Err(format!("unknown request: {other}")),
    }
}

#[cfg(target_os = "macos")]
pub use mac::{open_board, save_now, set_state_file};

#[cfg(target_os = "macos")]
mod mac {
    use super::{ask, board_frame, classify, system_may_open, Ask, Frame, Target, WindowState, BOARD_MIN};
    use super::Latest;
    use objc2::rc::{Retained, Weak};
    use objc2::runtime::{NSObject, ProtocolObject};
    use objc2::{define_class, msg_send, sel, MainThreadMarker, MainThreadOnly};
    use objc2_app_kit::{NSApplication, NSBackingStoreType, NSEventModifierFlags, NSMenu, NSMenuItem, NSScreen, NSWindow,
        NSWindowDelegate, NSWindowStyleMask};
    use objc2_foundation::{NSNotification, NSObjectProtocol, NSPoint, NSRect, NSSize, NSString};
    use raw_window_handle::{AppKitWindowHandle, HandleError, HasWindowHandle, RawWindowHandle, WindowHandle};
    use std::cell::RefCell;
    use std::path::PathBuf;
    use std::ptr::NonNull;
    use std::rc::Rc;
    use std::sync::OnceLock;
    use std::time::Duration;
    use wry::{NewWindowResponse, WebView, WebViewBuilder};

    static STATE_FILE: OnceLock<PathBuf> = OnceLock::new();

    /// Where the board window's place is kept: `todo-app-window.json` beside the app's settings file.
    pub fn set_state_file(file: PathBuf) { let _ = STATE_FILE.set(file); }

    struct Board { window: Retained<NSWindow>, _delegate: Retained<Delegate>, webview: Rc<WebView>, url: String }

    #[derive(Default)]
    struct Windows { board: Option<Board> }

    thread_local! {
        /// The windows live on the main thread, as AppKit wants. No borrow is held across a call into AppKit or
        /// WebKit: those can call back into the delegate below.
        static WINDOWS: RefCell<Windows> = RefCell::new(Windows::default());
    }

    define_class!(
        #[unsafe(super(NSObject))]
        #[thread_kind = MainThreadOnly]
        struct Delegate;

        unsafe impl NSObjectProtocol for Delegate {}

        unsafe impl NSWindowDelegate for Delegate {
            /// A drag sends many of these; the place is kept once the window has stood still for half a second.
            #[unsafe(method(windowDidMove:))]
            fn did_move(&self, _notification: &NSNotification) { save_when_still(); }

            #[unsafe(method(windowDidEndLiveResize:))]
            fn did_resize(&self, notification: &NSNotification) { self.placed(notification); }

            /// Closing only hides the board: its page, drafts and live stream stay for the next click on the tray.
            #[unsafe(method(windowWillClose:))]
            fn will_close(&self, notification: &NSNotification) { self.placed(notification); }
        }
    );

    static MOVES: Latest = Latest::new();

    fn save_when_still() {
        let moved = MOVES.take();
        dispatch::Queue::main().exec_after(Duration::from_millis(500), move || {
            if !MOVES.is_newest(moved) { return; }
            let frame = WINDOWS.with_borrow(|windows| windows.board.as_ref().map(|board| board.window.frame()));
            if let Some(frame) = frame { save_place(frame); }
        });
    }

    /// Keeps the board's place now: a quit skips the half second `save_when_still` waits. Main thread only.
    pub fn save_now() {
        if MainThreadMarker::new().is_none() { return; }
        let frame = WINDOWS.with_borrow(|windows| windows.board.as_ref().map(|board| board.window.frame()));
        if let Some(frame) = frame { save_place(frame); }
    }

    fn save_place(frame: NSRect) {
        let Some(file) = STATE_FILE.get() else { return };
        if let Err(error) = (WindowState { board: Some(frame_of(frame)) }).save(file) { eprintln!("sdlc-todo: {error}"); }
    }

    impl Delegate {
        fn new(mtm: MainThreadMarker) -> Retained<Delegate> {
            let this = mtm.alloc::<Delegate>().set_ivars(());
            unsafe { msg_send![super(this), init] }
        }

        /// Keeps the board's place for the next run.
        fn placed(&self, notification: &NSNotification) {
            let Some(window) = notification.object().and_then(|object| object.downcast::<NSWindow>().ok()) else { return };
            save_place(window.frame());
        }
    }

    /// The window's content view as the raw handle wry attaches to; wry then sets its own view as the content.
    #[derive(Clone, Copy)]
    struct Host(NonNull<std::ffi::c_void>);

    impl Host {
        fn of(window: &NSWindow) -> Result<Host, String> {
            let view = window.contentView().ok_or("the window has no content view")?;
            Ok(Host(NonNull::from(&*view).cast()))
        }
    }

    impl HasWindowHandle for Host {
        fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
            // Safety: the view belongs to a window that outlives this call (the caller holds it).
            Ok(unsafe { WindowHandle::borrow_raw(RawWindowHandle::AppKit(AppKitWindowHandle::new(self.0))) })
        }
    }

    fn rect(frame: Frame) -> NSRect { NSRect::new(NSPoint::new(frame.x, frame.y), NSSize::new(frame.width, frame.height)) }
    fn frame_of(rect: NSRect) -> Frame { Frame { x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height } }

    /// The visible frames of the screens, the main one (with the menu bar) first.
    fn screens(mtm: MainThreadMarker) -> Vec<Frame> {
        NSScreen::screens(mtm).iter().map(|screen| frame_of(screen.visibleFrame())).collect()
    }

    fn new_window(mtm: MainThreadMarker, frame: Frame, title: &str) -> Retained<NSWindow> {
        let style = NSWindowStyleMask::Titled | NSWindowStyleMask::Closable | NSWindowStyleMask::Miniaturizable | NSWindowStyleMask::Resizable;
        // initWithContentRect takes the content size; the frame wanted includes the title bar.
        let window = unsafe { NSWindow::initWithContentRect_styleMask_backing_defer(mtm.alloc(), rect(frame), style, NSBackingStoreType::Buffered, false) };
        // Made outside a window controller: closing must not free the window under the Retained that holds it.
        unsafe { window.setReleasedWhenClosed(false) };
        window.setFrame_display(rect(frame), false);
        window.setTitle(&NSString::from_str(title));
        window
    }

    fn bring_forward(mtm: MainThreadMarker, window: &NSWindow) {
        window.makeKeyAndOrderFront(None);
        #[allow(deprecated)]
        NSApplication::sharedApplication(mtm).activateIgnoringOtherApps(true);
    }

    /// The page's title on the window; a weak link, so a page never keeps its own window alive.
    fn title_follower(window: &NSWindow) -> impl Fn(String) + 'static {
        let window = Weak::from(window);
        move |title: String| {
            if let Some(window) = window.load() { if !title.is_empty() { window.setTitle(&NSString::from_str(&title)); } }
        }
    }

    /// winit's menu has no Edit menu, and a web page gets copy, paste and undo from the menu's key equivalents
    /// (⌘C, ⌘V, …), so the board's text fields need one. ⌘W closes the window in front.
    fn add_edit_menu(mtm: MainThreadMarker) {
        thread_local! { static ADDED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) }; }
        if ADDED.replace(true) { return; }
        let Some(main) = NSApplication::sharedApplication(mtm).mainMenu() else { return };
        // An item without an action is a separator.
        let submenu = |title: &str, items: &[(&str, Option<objc2::runtime::Sel>, &str)]| {
            let menu = NSMenu::initWithTitle(mtm.alloc(), &NSString::from_str(title));
            for (name, action, key) in items {
                if action.is_none() { menu.addItem(&NSMenuItem::separatorItem(mtm)); continue; }
                let item = unsafe { NSMenuItem::initWithTitle_action_keyEquivalent(mtm.alloc(), &NSString::from_str(name), *action, &NSString::from_str(key)) };
                item.setKeyEquivalentModifierMask(NSEventModifierFlags::Command);
                menu.addItem(&item);
            }
            let holder = NSMenuItem::new(mtm);
            holder.setSubmenu(Some(&menu));
            main.addItem(&holder);
        };
        submenu("Edit", &[("Undo", Some(sel!(undo:)), "z"), ("Redo", Some(sel!(redo:)), "Z"), ("", None, ""), ("Cut", Some(sel!(cut:)), "x"),
            ("Copy", Some(sel!(copy:)), "c"), ("Paste", Some(sel!(paste:)), "v"), ("Select All", Some(sel!(selectAll:)), "a")]);
        submenu("Window", &[("Minimize", Some(sel!(performMiniaturize:)), "m"), ("Close", Some(sel!(performClose:)), "w")]);
    }

    /// Opens the board at `url`, or brings the open one forward and, when the server was replaced, loads its new
    /// address. With `show` false the board only follows the new address, hidden or not. Main thread only. An error
    /// means the webview could not start; the caller falls back to a browser.
    pub fn open_board(url: &str, title: &str, show: bool) -> Result<(), String> {
        let mtm = MainThreadMarker::new().ok_or("the board window opens on the main thread only")?;
        let open = WINDOWS.with_borrow(|windows| windows.board.as_ref().map(|board| (board.window.clone(), board.webview.clone(), board.url == url)));
        if let Some((window, webview, same)) = open {
            if !same {
                webview.load_url(url).map_err(|e| e.to_string())?;
                WINDOWS.with_borrow_mut(|windows| if let Some(board) = windows.board.as_mut() { board.url = url.to_string(); });
            }
            if show { bring_forward(mtm, &window); }
            return Ok(());
        }
        // A replaced server for a board that never opened here (it fell back to a browser): nothing to follow.
        if !show { return Ok(()); }
        add_edit_menu(mtm);
        let saved = STATE_FILE.get().map(|file| WindowState::load(file)).unwrap_or_default();
        let window = new_window(mtm, board_frame(saved.board, &screens(mtm)), title);
        let delegate = Delegate::new(mtm);
        window.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
        window.setMinSize(NSSize::new(BOARD_MIN.0, BOARD_MIN.1));
        let built = WebViewBuilder::new()
            .with_url(url)
            .with_ipc_handler(|request| { guarded(|| board_message(&request.uri().to_string(), request.body())); })
            .with_new_window_req_handler(|to, _| guarded(|| { hand_off(&to); NewWindowResponse::Deny }).unwrap_or(NewWindowResponse::Deny))
            .with_navigation_handler(|to: String| guarded(|| board_navigation(&to)).unwrap_or(false))
            .with_document_title_changed_handler(title_follower(&window))
            .build(&Host::of(&window)?);
        let webview = match built {
            Ok(webview) => webview,
            Err(error) => { window.setDelegate(None); window.close(); return Err(error.to_string()); }
        };
        WINDOWS.with_borrow_mut(|windows| windows.board = Some(Board { window: window.clone(), _delegate: delegate, webview: Rc::new(webview), url: url.to_string() }));
        bring_forward(mtm, &window);
        Ok(())
    }

    /// The ticket window takes the left side of the screen the board is on; Chrome needs the main screen's height to
    /// turn AppKit's bottom-left coordinates into its own.
    fn open_ticket(url: &str, follow: bool) {
        let Some(mtm) = MainThreadMarker::new() else { return };
        let all = NSScreen::screens(mtm);
        let main_height = all.iter().next().map(|screen| screen.frame().size.height).unwrap_or(900.0);
        let visible = WINDOWS.with_borrow(|windows| windows.board.as_ref().and_then(|board| board.window.screen()))
            .or_else(|| NSScreen::mainScreen(mtm))
            .map(|screen| frame_of(screen.visibleFrame()))
            .unwrap_or(Frame { x: 0.0, y: 0.0, width: 1440.0, height: main_height });
        crate::ticket::open(url.to_string(), follow, visible, main_height);
    }

    /// A link the board does not show itself: http(s) to the Chrome ticket window, `mailto:` to the mail app; anything
    /// else is refused, since the system's handler would launch it.
    fn hand_off(url: &str) {
        match classify(url) {
            Target::External => open_ticket(url, false),
            Target::Board => crate::open_url(url),
            Target::Other if system_may_open(url) => crate::open_url(url),
            Target::Other => eprintln!("sdlc-todo: refused to open {url}: only http(s) and mailto: links leave the board"),
        }
    }

    /// The board page stays on this machine's server (a replaced server has a new port); every other address is
    /// handed off and cancelled, so the board keeps its page, token and drafts.
    fn board_navigation(to: &str) -> bool {
        if classify(to) == Target::Board || to.starts_with("about:") { return true; }
        hand_off(to);
        false
    }

    /// Runs a handler WebKit calls: a panic must not unwind into Objective-C, so it is logged and the call answers
    /// None.
    fn guarded<T>(body: impl FnOnce() -> T) -> Option<T> {
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(body))
            .map_err(|_| eprintln!("sdlc-todo: a board window handler panicked"))
            .ok()
    }

    /// A message from the board page (see `ask`): a ticket to open or follow in the Chrome ticket window.
    fn board_message(from: &str, body: &str) {
        let board = WINDOWS.with_borrow(|windows| windows.board.as_ref().map(|board| board.url.split("/#").next().unwrap_or("").to_string()));
        match ask(from, &board.unwrap_or_default(), body) {
            Ok(Ask::Open(url)) => open_ticket(&url, false),
            Ok(Ask::Follow(url)) => open_ticket(&url, true),
            Err(error) => eprintln!("sdlc-todo: ignored a message from the board: {error}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCREEN: Frame = Frame { x: 0.0, y: 0.0, width: 1512.0, height: 944.0 };

    #[test]
    fn the_ticket_window_takes_the_left_45_percent_at_full_height() {
        assert_eq!(ticket_frame(SCREEN), Frame { x: 0.0, y: 0.0, width: 680.0, height: 944.0 });
        // A second display to the left, below the menu bar's line: its own origin.
        let left = Frame { x: -1920.0, y: 25.0, width: 1920.0, height: 1055.0 };
        assert_eq!(ticket_frame(left), Frame { x: -1920.0, y: 25.0, width: 864.0, height: 1055.0 });
    }

    #[test]
    fn the_board_keeps_its_saved_place_while_it_is_on_a_screen() {
        let saved = Frame { x: 100.0, y: 50.0, width: 1000.0, height: 700.0 };
        assert_eq!(board_frame(Some(saved), &[SCREEN]), saved);
        // Without a saved place, or with one on a display that is gone or too small to use, it takes the rest of
        // the main screen beside the ticket window.
        let beside = Frame { x: 680.0, y: 0.0, width: 832.0, height: 944.0 };
        assert_eq!(board_frame(None, &[SCREEN]), beside);
        assert_eq!(board_frame(Some(Frame { x: 4000.0, ..saved }), &[SCREEN]), beside);
        assert_eq!(board_frame(Some(Frame { width: 200.0, ..saved }), &[SCREEN]), beside);
        assert_eq!(board_frame(Some(Frame { x: f64::NAN, ..saved }), &[SCREEN]), beside);
        // On the second display it was moved to, it stays.
        let other = Frame { x: 1512.0, y: 0.0, width: 1920.0, height: 1080.0 };
        let there = Frame { x: 1700.0, ..saved };
        assert_eq!(board_frame(Some(there), &[SCREEN, other]), there);
    }

    #[test]
    fn a_saved_place_is_held_inside_its_screen() {
        // Huge: no bigger than the screen's visible area, and inside it.
        let huge = Frame { x: 100.0, y: 50.0, width: 1e9, height: 1e9 };
        assert_eq!(board_frame(Some(huge), &[SCREEN]), SCREEN);
        // Off the top: the title bar comes back below the top edge (AppKit's y grows upwards); x is kept.
        let high = Frame { x: 300.0, y: 600.0, width: 1000.0, height: 700.0 };
        assert_eq!(board_frame(Some(high), &[SCREEN]), Frame { x: 300.0, y: 244.0, width: 1000.0, height: 700.0 });
        // Hanging off the right and bottom edges: pulled in on the screen it overlaps most.
        let low = Frame { x: 1000.0, y: -300.0, width: 1000.0, height: 700.0 };
        assert_eq!(board_frame(Some(low), &[SCREEN]), Frame { x: 512.0, y: 0.0, width: 1000.0, height: 700.0 });
    }

    #[test]
    fn board_links_and_ticket_links_are_told_apart() {
        for url in ["http://127.0.0.1:51234/#t=abc&app=1", "http://localhost:3000/x", "http://[::1]:8080/", "HTTP://127.0.0.1/"] {
            assert_eq!(classify(url), Target::Board, "{url}");
        }
        for url in ["https://example.atlassian.net/browse/PROJ-1528", "http://127.0.0.1.evil.example/", "https://127.0.0.1@evil.example/",
            "https://example.com:8443/a?b#c"] {
            assert_eq!(classify(url), Target::External, "{url}");
        }
        for url in ["about:blank", "mailto:a@b.c", "javascript:alert(1)", "file:///etc/hosts", "", "https://", "data:text/html,x"] {
            assert_eq!(classify(url), Target::Other, "{url}");
        }
    }

    const BOARD: &str = "http://127.0.0.1:51860";

    #[test]
    fn the_board_page_may_ask_for_a_ticket_and_nothing_else() {
        let from = "http://127.0.0.1:51860/";
        let ticket = "https://example.atlassian.net/browse/PROJ-1383";
        assert_eq!(ask(from, BOARD, &format!(r#"{{"open":"{ticket}"}}"#)), Ok(Ask::Open(ticket.into())));
        assert_eq!(ask(BOARD, BOARD, &format!(r#"{{"follow":"{ticket}"}}"#)), Ok(Ask::Follow(ticket.into())));
        // Only the board's own page: another port, another host, a lookalike host.
        for other in ["http://127.0.0.1:51861/", "http://localhost:51860/", "https://example.atlassian.net/", "http://127.0.0.1:518600/",
            "http://127.0.0.1:51860.evil.example/", ""] {
            assert!(ask(other, BOARD, &format!(r#"{{"open":"{ticket}"}}"#)).is_err(), "{other}");
        }
        // Not JSON, not one field, an unknown request, a non-string address.
        for body in ["", "open", r#"["open"]"#, "{}", r#"{"open":"https://e.x/","follow":"https://e.x/"}"#, r#"{"close":"https://e.x/"}"#,
            r#"{"open":42}"#, r#"{"open":null}"#] {
            assert!(ask(from, BOARD, body).is_err(), "{body}");
        }
        // Only an http(s) address off this machine: never the board's own server, a file, a scheme handler.
        for url in ["http://127.0.0.1:51860/#t=x", "http://localhost/", "file:///Applications/Calculator.app", "javascript:alert(1)",
            "vscode://file/etc/hosts", "data:text/html,x", "mailto:a@b.c"] {
            assert!(ask(from, BOARD, &serde_json::json!({ "open": url }).to_string()).is_err(), "{url}");
        }
        // A huge message is refused before it is parsed.
        let huge = serde_json::json!({ "open": format!("https://e.x/{}", "a".repeat(9000)) }).to_string();
        assert!(ask(from, BOARD, &huge).unwrap_err().contains("over 8192"));
    }

    /// The sender's address reaches the handler through http::Uri, which drops the token fragment; the board's page
    /// must still be recognised.
    #[cfg(target_os = "macos")]
    #[test]
    fn the_board_pages_address_survives_the_ipc_request() {
        let uri: wry::http::Uri = "http://127.0.0.1:51860/#t=0123456789abcdef0123456789abcdef&app=1".parse().unwrap();
        assert!(ask(&uri.to_string(), BOARD, r#"{"open":"https://e.x/browse/A-1"}"#).is_ok(), "{uri}");
    }

    #[test]
    fn only_the_newest_move_saves() {
        let latest = Latest::new();
        let (first, second, third) = (latest.take(), latest.take(), latest.take());
        assert!(!latest.is_newest(first) && !latest.is_newest(second) && latest.is_newest(third));
    }

    #[test]
    fn only_mail_links_go_to_the_system_handler() {
        // Never to Chrome, never to `open`: these could launch an app through LaunchServices.
        for url in ["file:///Applications/Calculator.app", "FILE:///tmp/evil.app", "data:text/html,<script>x</script>",
            "chrome://settings", "blob:http://127.0.0.1:5000/0b9c", "javascript:alert(1)", "javascript://%0aalert(1)",
            "vscode://file/etc/hosts", "x-apple.systempreferences:com.apple.preference.security", "ftp://e.x/a", "mailto"] {
            assert_eq!(classify(url), Target::Other, "{url}");
            assert!(!system_may_open(url), "{url}");
        }
        for url in ["mailto:qa@example.com", "MAILTO:qa@example.com?subject=A20"] {
            assert!(system_may_open(url), "{url}");
        }
    }

    #[test]
    fn the_window_state_file_round_trips_and_tolerates_breakage() {
        let dir = std::env::temp_dir().join(format!("sdlc-todo-window-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("todo-app-window.json");
        assert_eq!(WindowState::load(&file), WindowState::default());
        let state = WindowState { board: Some(Frame { x: 680.0, y: 0.0, width: 832.0, height: 944.0 }) };
        state.save(&file).unwrap();
        assert!(!dir.join("todo-app-window.json.tmp").exists());
        assert_eq!(WindowState::load(&file), state);
        // The format the file keeps, so a person or a later version can read it.
        let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        assert_eq!(json, serde_json::json!({ "board": { "x": 680.0, "y": 0.0, "width": 832.0, "height": 944.0 } }));
        // Fields it does not know and a missing board are fine; broken JSON means the default place.
        std::fs::write(&file, r#"{ "ticket": 1 }"#).unwrap();
        assert_eq!(WindowState::load(&file), WindowState::default());
        std::fs::write(&file, "{ not json").unwrap();
        assert_eq!(WindowState::load(&file), WindowState::default());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
