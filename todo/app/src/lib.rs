//! sdlc-todo: a small tray app for the sdlc-kit to-do. It shows the web board in a window and never edits todo.md
//! itself; every change goes through the same web API as the browser page, so the TUI, page and app agree.
mod board;
mod bridge;
mod fonts;
mod i18n;
mod links;
mod model;
mod prefs;
mod server;
mod system;
mod ticket;
#[cfg(desktop)]
mod tray;
mod window;

use board::View;
use i18n::{t, Lang};
use model::Model;
use prefs::Prefs;
use server::{Launcher, Server, Session};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use tauri::{AppHandle, Manager, RunEvent};

/// A poisoned lock still holds sound data here (every change is one assignment); a handler must not panic over it.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> { mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) }

#[derive(Clone, Debug, PartialEq)]
enum Conn { Connecting, Live, Offline(String) }

struct Shared {
    model: Model,
    conn: Conn,
    session: Option<Session>,
    /// The server whose page the board window shows or loads.
    loaded: Option<Session>,
    /// The server this app started.
    server: Option<Server>,
}

impl Shared {
    /// The session the board should show, and whether to bring it forward (`requested`), or None to leave it be.
    /// `window` says whether the board window exists.
    fn board_to_open(&self, requested: bool, window: bool) -> Option<(Session, bool)> {
        if self.conn != Conn::Live { return None; }
        let session = self.session.as_ref()?;
        // The page is tied to its server's port and token. After a server replacement an existing window loads the
        // new address in place, open or hidden, without coming forward.
        let replaced = window && self.loaded.as_ref() != Some(session);
        (requested || replaced).then(|| (session.clone(), requested))
    }
}

struct Shell {
    shared: Mutex<Shared>,
    prefs: Mutex<Prefs>,
    prefs_error: Mutex<Option<String>>,
    prefs_file: PathBuf,
    window_file: PathBuf,
    start_lang: Lang,
    /// The server ports whose page may use the bridge.
    allowed: Mutex<HashSet<u16>>,
}

impl Shell {
    /// The list's language, once known.
    fn lang(&self) -> Lang {
        let shared = lock(&self.shared);
        if shared.model.lang.is_empty() { self.start_lang } else { Lang::parse(&shared.model.lang) }
    }
}

/// `background` (`--background`, or SDLC_TODO_BACKGROUND=1 for login items) starts in the tray without opening the board.
#[derive(Debug)]
struct Args { session: PathBuf, kit: PathBuf, node: String, lang: String, background: bool }

const USAGE: &str = "usage: sdlc-todo [--session FILE] [--kit DIR] [--node PATH] [--lang en|ko] [--background]";

/// Reads the environment (`env`) and the command line (`list`, without the program).
fn args(env: impl Fn(&str) -> Option<String>, list: impl Iterator<Item = String>, exe: Option<PathBuf>) -> Result<Args, String> {
    let home = env("HOME").or_else(|| env("USERPROFILE")).map(PathBuf::from).unwrap_or_default();
    let todo = env("SDLC_TODO").map(PathBuf::from).unwrap_or_else(|| home.join(".sdlc").join("todo.md"));
    let mut parsed = Args {
        session: env("SDLC_TODO_SESSION").map(PathBuf::from)
            .unwrap_or_else(|| todo.parent().map(|d| d.join("todo-web.json")).unwrap_or_default()),
        // An app bundle names the kit and node in its Info.plist environment; built in place, the binary sits at
        // <kit>/todo/app/target/release/.
        kit: env("SDLC_TODO_KIT").map(PathBuf::from).or_else(|| exe.and_then(|exe| exe.ancestors().nth(5).map(PathBuf::from))).unwrap_or_default(),
        node: env("SDLC_TODO_NODE").unwrap_or_else(|| "node".into()),
        lang: env("SDLC_TODO_LANG").unwrap_or_else(|| "en".into()),
        background: env("SDLC_TODO_BACKGROUND").is_some_and(|value| value == "1"),
    };
    let mut list = list;
    while let Some(flag) = list.next() {
        if flag == "--background" { parsed.background = true; continue; }
        // Finder and LaunchServices may add their own process argument.
        if flag.starts_with("-psn_") { continue; }
        let value = list.next().ok_or_else(|| format!("missing value for {flag}"))?;
        match flag.as_str() {
            "--session" => parsed.session = value.into(),
            "--kit" => parsed.kit = value.into(),
            "--node" => parsed.node = value,
            "--lang" => parsed.lang = value,
            _ => return Err(format!("unknown option: {flag}\n{USAGE}")),
        }
    }
    if !parsed.kit.join("todo").join("todo.mjs").is_file() { return Err(format!("no todo/todo.mjs under --kit {}", parsed.kit.display())); }
    Ok(parsed)
}

/// One app per list: the identifier that single-instance (and WebView2's data folder) go by, for the list whose
/// session file this is. FNV-1a, so it stays the same from build to build.
fn instance(identifier: &str, session: &Path) -> String {
    let path = std::path::absolute(session).unwrap_or_else(|_| session.to_path_buf());
    let hash = path.to_string_lossy().bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| (hash ^ u64::from(byte)).wrapping_mul(0x100_0000_01b3));
    format!("{identifier}.l{hash:016x}")
}

/// Finds or starts the server, then follows its events; reconnects whenever the stream drops. With `open_once`, the
/// board opens the first time the server answers with the list, as a launch shows it.
fn connect(app: AppHandle, launcher: Launcher, mut open_once: bool) {
    let mut before: Option<Model> = None;
    let shell = app.state::<Shell>();
    let offline = |reason: String| {
        lock(&shell.shared).conn = Conn::Offline(reason);
        board::offline(&app);
    };
    loop {
        let session = match launcher.find_live() {
            Some(session) => session,
            None => {
                {
                    let mut shared = lock(&shell.shared);
                    // Reap an exited server before its successor checks file-lock owners.
                    if let Some(server) = shared.server.as_mut() { server.reap(); }
                }
                match launcher.start() {
                    Ok((server, session)) => {
                        let old = lock(&shell.shared).server.replace(server);
                        if let Some(mut old) = old { old.stop(); }
                        session
                    }
                    Err(error) => {
                        offline(error);
                        std::thread::sleep(Duration::from_secs(5));
                        continue;
                    }
                }
            }
        };
        lock(&shell.shared).session = Some(session.clone());
        let ended = server::follow(&session, |model| {
            let lang = if model.lang.is_empty() { shell.start_lang } else { Lang::parse(&model.lang) };
            if let Some(before) = &before {
                for item in model.newly_waiting(before) {
                    let _ = notify_rust::Notification::new().summary(t(lang, "notify.title"))
                        .body(&format!("{} · {}", item.ask(lang), item.title)).show();
                }
            }
            before = Some(model.clone());
            #[cfg(desktop)]
            tray::show_count(&app, model.waiting(), lang);
            {
                let mut shared = lock(&shell.shared);
                shared.model = model;
                shared.conn = Conn::Live;
            }
            board::follow_server(&app, std::mem::take(&mut open_once));
        });
        if let Err(error) = ended { offline(error); }
        std::thread::sleep(Duration::from_secs(1));
    }
}

/// Ends the app; `leave` then keeps the board's place and stops the server it started.
fn leave(app: &AppHandle) {
    board::save_place(app);
    let server = lock(&app.state::<Shell>().shared).server.take();
    if let Some(mut server) = server { server.stop(); }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    if let Err(error) = start() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn start() -> Result<(), String> {
    // Without a sender, mac-notification-sys asks AppleScript for application "use_default" before the first
    // notification, and macOS answers with a "Where is use_default?" chooser. Name the sender up front.
    #[cfg(target_os = "macos")]
    {
        let bundled = std::env::current_exe().is_ok_and(|exe| exe.to_string_lossy().contains(".app/Contents/MacOS/"));
        let _ = notify_rust::set_application(if bundled { "dev.sdlc-kit.todo" } else { "com.apple.Terminal" });
    }
    let args = args(|name| std::env::var_os(name).map(|value| value.to_string_lossy().to_string()), std::env::args().skip(1), std::env::current_exe().ok())?;
    let lang = Lang::parse(&args.lang);
    let prefs_file = args.session.with_file_name("todo-app.json");
    let (prefs, prefs_error) = Prefs::load(&prefs_file);
    let shell = Shell {
        shared: Mutex::new(Shared { model: Model::default(), conn: Conn::Connecting, session: None, loaded: None, server: None }),
        prefs: Mutex::new(prefs), prefs_error: Mutex::new(prefs_error),
        window_file: prefs_file.with_file_name("todo-app-window.json"), prefs_file,
        start_lang: lang, allowed: Mutex::new(HashSet::new()),
    };
    let background = args.background;
    let launcher = Arc::new(Mutex::new(Some(Launcher { session_file: args.session.clone(), kit: args.kit, node: args.node, lang: args.lang })));
    let mut context = tauri::generate_context!();
    let identifier = instance(&context.config().identifier, &args.session);
    context.config_mut().identifier = identifier;

    let mut builder = tauri::Builder::default();
    #[cfg(desktop)]
    {
        // A second launch on the same list ends here and brings this one's board forward.
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, argv, _| {
            if !argv.iter().any(|arg| arg == "--background") { board::later(app, |app| board::show(app, View::Board)); }
        }));
    }
    let app = builder
        .manage(shell)
        .invoke_handler(tauri::generate_handler![bridge::ticket, bridge::app_state, bridge::save_memo, bridge::save_view, bridge::open_terminal])
        .setup(move |app| {
            let handle = app.handle().clone();
            #[cfg(desktop)]
            tray::build(&handle, lang, |app, pick| match pick {
                tray::Pick::Board => board::later(app, |app| board::show(app, View::Board)),
                tray::Pick::List => board::later(app, |app| board::show(app, View::List)),
                tray::Pick::Quit => app.exit(0),
            })?;
            if let Some(launcher) = lock(&launcher).take() { board::later(&handle, move |app| connect(app.clone(), launcher, !background)); }
            // macOS asks once whether the app may control Chrome (for the ticket window); ask now, not at the first ticket.
            #[cfg(target_os = "macos")]
            ticket::ask_permission_early();
            Ok(())
        })
        .build(context)
        .map_err(|e| e.to_string())?;
    app.run(|app, event| match event {
        // The last window going away leaves the tray; only Quit (which carries a code) and the system end the app.
        RunEvent::ExitRequested { code: None, api, .. } => api.prevent_exit(),
        RunEvent::Exit => leave(app),
        #[cfg(target_os = "macos")]
        RunEvent::Reopen { has_visible_windows, .. } => if !has_visible_windows { board::later(app, |app| board::show(app, View::Board)) },
        _ => {}
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(port: u16) -> Session { Session { port, token: "0123456789abcdef0123456789abcdef".into() } }
    fn shared(conn: Conn, session: Option<Session>, loaded: Option<Session>) -> Shared {
        Shared { model: Model::default(), conn, session, loaded, server: None }
    }

    #[test]
    fn the_board_opens_on_request_and_follows_a_replaced_server_without_coming_forward() {
        let opens = |shared: &Shared, requested, window| shared.board_to_open(requested, window).map(|(s, show)| (s.port, show));
        let live = shared(Conn::Live, Some(session(2)), Some(session(2)));
        assert_eq!(opens(&live, true, true), Some((2, true)));
        assert_eq!(opens(&live, false, true), None, "nothing changed");
        let replaced = shared(Conn::Live, Some(session(2)), Some(session(1)));
        assert_eq!(opens(&replaced, false, true), Some((2, false)), "reloads in place");
        assert_eq!(opens(&replaced, false, false), None, "a tray without a window makes none");
        // The shell's own page (no server yet) gives way to the board once the server answers.
        assert_eq!(opens(&shared(Conn::Live, Some(session(2)), None), false, true), Some((2, false)));
        for conn in [Conn::Connecting, Conn::Offline("x".into())] {
            assert_eq!(opens(&shared(conn, Some(session(2)), None), true, true), None, "no dead address");
        }
    }

    #[test]
    fn one_app_per_list() {
        let id = |path: &str| instance("dev.sdlc-kit.todo", Path::new(path));
        assert_eq!(id("/a/todo-web.json"), id("/a/todo-web.json"));
        assert_ne!(id("/a/todo-web.json"), id("/b/todo-web.json"));
        // Goes into a socket path (at most 104 bytes on macOS) and a mutex name.
        let long = id(&"/x".repeat(500));
        assert!(long.len() < 60 && long.chars().all(|c| c.is_ascii_alphanumeric() || ".-".contains(c)), "{long}");
    }

    #[test]
    fn flags_win_over_the_environment() {
        let kit = std::env::temp_dir().join(format!("sdlc-todo-kit-{}", std::process::id()));
        std::fs::create_dir_all(kit.join("todo")).unwrap();
        std::fs::write(kit.join("todo").join("todo.mjs"), "").unwrap();
        let kit_text = kit.to_string_lossy().to_string();
        let read = |env: &[(&str, &str)], list: &[&str]| {
            let env: Vec<(String, String)> = env.iter().map(|(k, v)| (k.to_string(), v.to_string())).chain([("SDLC_TODO_KIT".to_string(), kit_text.clone())]).collect();
            args(move |name| env.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone()), list.iter().map(|s| s.to_string()).collect::<Vec<_>>().into_iter(), None)
        };
        let plain = read(&[("HOME", "/h")], &[]).unwrap();
        assert_eq!(plain.session, Path::new("/h").join(".sdlc").join("todo-web.json"));
        assert_eq!((plain.node.as_str(), plain.lang.as_str(), plain.background), ("node", "en", false));
        let env = [("SDLC_TODO", "/l/todo.md"), ("SDLC_TODO_NODE", "/n"), ("SDLC_TODO_LANG", "ko"), ("SDLC_TODO_BACKGROUND", "1")];
        let set = read(&env, &[]).unwrap();
        assert_eq!((set.session, set.node, set.lang, set.background), (Path::new("/l").join("todo-web.json"), "/n".into(), "ko".into(), true));
        assert_eq!(read(&[("SDLC_TODO_SESSION", "/s.json")], &[]).unwrap().session, Path::new("/s.json"));
        let flags = read(&env, &["--lang", "en", "--session", "/f.json", "--background", "-psn_0_1"]).unwrap();
        assert_eq!((flags.session, flags.lang), (PathBuf::from("/f.json"), "en".to_string()));
        assert!(read(&[], &["--what", "x"]).unwrap_err().contains("usage:"));
        assert!(read(&[], &["--lang"]).unwrap_err().contains("missing value"));
        assert!(read(&[], &["--kit", "/nowhere"]).is_err());
        std::fs::remove_dir_all(&kit).unwrap();
    }

    #[test]
    fn the_build_names_the_same_commands_the_bridge_allows() {
        let build = include_str!("../build.rs");
        for command in bridge::COMMANDS { assert!(build.contains(&format!("\"{command}\"")), "{command}"); }
    }
}
