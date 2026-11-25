//! The ticket window: a ticket the board opens shows in the person's own Google Chrome (default profile), where
//! their Jira login already lives, as one window docked at the screen's left edge (45% wide, full height, as board.js
//! v3.3.4 places its popup) and reused for every later ticket. The board window and its panel never move.
//!
//! Chrome is driven with JavaScript for Automation (`osascript -l JavaScript`) addressed by process id, not by name:
//! test browsers started by automation tools also run as "Google Chrome", and a name picks any of them. The default
//! profile's instance is the one started without `--user-data-dir`. macOS asks once for permission to control
//! Chrome; the app asks at start, and again before a ticket, so the question never runs into the script's time
//! limit. Without Chrome, without that permission, or when the script fails, an opened ticket goes to the default
//! browser, unplaced, and the reason is logged. A script that runs out of time may still have made the window, so
//! then nothing else opens; the next click finds that window by its address.
// Only the macOS board window uses these yet; the tests run them everywhere.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]
use crate::window::{ticket_frame, Frame};

/// Chrome's window bounds for a ticket on the screen whose free area is `visible`: x, y, width, height in whole points.
/// Chrome's scripting and `Frame` share the top-left origin of the main screen.
pub fn chrome_bounds(visible: Frame) -> [i64; 4] {
    let frame = ticket_frame(visible);
    [frame.x.round() as i64, frame.y.round() as i64, frame.width.round() as i64, frame.height.round() as i64]
}

/// The process id of Chrome's default-profile instance in `ps -xww -o pid=,args=` output (this user's processes only): the main Chrome binary
/// (not a helper) started without its own `--user-data-dir`, which automation tools always pass.
pub fn default_chrome_pid(ps: &str) -> Option<u32> {
    ps.lines().find_map(|line| {
        let (pid, args) = line.trim_start().split_once(' ')?;
        let args = args.trim_start();
        // The program path, up to its first flag (the path itself has spaces).
        let main = args.split(" --").next().is_some_and(|program| program.ends_with("Google Chrome.app/Contents/MacOS/Google Chrome"));
        (main && !args.contains("--user-data-dir") && !args.contains("--headless")).then(|| pid.parse().ok()).flatten()
    })
}

/// A JavaScript string literal for `text`: JSON escapes quotes, backslashes and control characters.
fn js_string(text: &str) -> String { serde_json::to_string(text).unwrap_or_else(|_| "\"\"".into()) }

/// The script for Chrome `pid`: it finds the ticket window and shows `url` there. Opening (`follow` false) uses the
/// window the last ticket went to (`reuse`), else, only while `recover`ing from a run of ours that timed out (it may
/// have made a window it could not report), a window already showing `url`, else a new window; it places the window at
/// `bounds` and puts it in front of Chrome's other windows. Following uses only `reuse`, left where the person put
/// it, and makes none: a window of the person's own is never taken over. A window already showing `url` is not
/// reloaded. It prints the window's id, or nothing when following found no window.
pub fn script(pid: u32, url: &str, reuse: Option<i64>, bounds: [i64; 4], follow: bool, recover: bool) -> String {
    let [x, y, width, height] = bounds;
    let reuse = reuse.map_or("null".to_string(), |id| id.to_string());
    let lookup = if recover && !follow {
        "if (win === null) { for (const each of chrome.windows()) { try { if (each.activeTab.url() === url) { win = each; break; } } catch (e) {} } }\n"
    } else { "" };
    format!(r#"(() => {{
const chrome = Application({pid});
const url = {url};
const reuse = {reuse};
const follow = {follow};
let win = null;
if (reuse !== null) {{ try {{ const found = chrome.windows.byId(reuse); found.id(); win = found; }} catch (e) {{}} }}
{lookup}if (win === null && follow) {{ return ""; }}
if (win === null) {{ win = chrome.Window().make(); }}
if (win.activeTab.url() !== url) {{ win.activeTab.url = url; }}
if (!follow) {{
  win.bounds = {{ x: {x}, y: {y}, width: {width}, height: {height} }};
  win.index = 1;
}}
return String(win.id());
}})()
"#, url = js_string(url))
}

/// procNotFound: the permission check found no running Chrome (it was started a moment ago and is not up yet).
pub const PROC_NOT_FOUND: i32 = -600;
/// How long a just-started Chrome gets to answer the permission check, and how often it is asked.
pub const PERMISSION_WAIT: (std::time::Duration, std::time::Duration) = (std::time::Duration::from_secs(5), std::time::Duration::from_millis(250));

/// Whether to ask again after the permission check answered `status`, `waited` after the first try.
pub fn ask_again(status: i32, waited: std::time::Duration) -> bool { status == PROC_NOT_FOUND && waited < PERMISSION_WAIT.0 }

/// One worker runs the tickets: a request while it runs only waits in `pending`, and the worker takes requests until
/// none waits. Returns whether this call was the worker. `run` gets each request; `running` says a worker is on it.
pub fn drain(pending: &std::sync::Mutex<Pending>, running: &std::sync::atomic::AtomicBool, mut run: impl FnMut(String, bool)) -> bool {
    use std::sync::atomic::Ordering::SeqCst;
    if running.swap(true, SeqCst) { return false; }
    loop {
        let next = pending.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
        match next {
            Some((url, follow)) => run(url, follow),
            None => {
                running.store(false, SeqCst);
                // A request pushed between the take and the store found the flag still set and left it here: take it
                // up, unless a new worker already has.
                let waiting = pending.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).0.is_some();
                if !waiting || running.swap(true, SeqCst) { return true; }
            }
        }
    }
}

/// The ticket waiting for Chrome. Requests that arrive while one runs are merged: the newest address wins, and the
/// merge opens (makes and brings forward the window) when any of them opened, so a click followed by a selection
/// still shows a window.
#[derive(Debug, Default, PartialEq)]
pub struct Pending(pub(crate) Option<(String, bool)>);

impl Pending {
    pub fn push(&mut self, url: String, follow: bool) {
        let follow = follow && self.0.as_ref().is_none_or(|(_, earlier)| *earlier);
        self.0 = Some((url, follow));
    }
    /// The ticket to run now, as (address, follow).
    pub fn take(&mut self) -> Option<(String, bool)> { self.0.take() }
}

/// What a run of the script came to, when it did not show the ticket.
#[derive(Debug, PartialEq)]
pub enum Failure {
    /// osascript did not answer in time and was stopped; it may still have made the window.
    TimedOut,
    Failed(String),
}

/// Runs `command` and returns its output, or stops it once `limit` passes (a Chrome that hangs). Its output is a line
/// or two, well inside the pipe buffers it waits on. A child it cannot watch is stopped too, never left running.
pub fn output_within(mut command: std::process::Command, limit: std::time::Duration) -> Result<std::process::Output, Failure> {
    use std::process::Stdio;
    let mut child = command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()
        .map_err(|e| Failure::Failed(e.to_string()))?;
    let deadline = std::time::Instant::now() + limit;
    let stop = |child: &mut std::process::Child| { let _ = child.kill(); let _ = child.wait(); };
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().map_err(|e| Failure::Failed(e.to_string())),
            Ok(None) if std::time::Instant::now() >= deadline => { stop(&mut child); return Err(Failure::TimedOut); }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(50)),
            Err(error) => { stop(&mut child); return Err(Failure::Failed(error.to_string())); }
        }
    }
}

#[cfg(target_os = "macos")]
pub use mac::{ask_permission_early, open};

#[cfg(target_os = "macos")]
mod mac {
    use super::{ask_again, chrome_bounds, default_chrome_pid, drain, output_within, script, Failure, Pending, PERMISSION_WAIT};
    use crate::window::Frame;
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    /// The Chrome instance and window the last ticket went to. Held while a ticket runs, so two clicks in a row make
    /// one window, not two.
    static LAST: Mutex<Option<(u32, i64)>> = Mutex::new(None);
    static PENDING: Mutex<Pending> = Mutex::new(Pending(None));
    /// The newest request's screen: the free area of the board's screen.
    static PLACE: Mutex<Option<Frame>> = Mutex::new(None);
    /// Set while the ticket worker runs (see `drain`).
    static RUNNING: AtomicBool = AtomicBool::new(false);
    /// Set after a run of ours timed out (it may have made a window it never reported); the next opening looks for
    /// a window on the ticket before making one, and a run that succeeds clears it.
    static RECOVER: AtomicBool = AtomicBool::new(false);
    /// How long Chrome gets to answer. The permission question is asked before this clock starts.
    const SCRIPT_LIMIT: Duration = Duration::from_secs(8);

    fn chrome_pid() -> Option<u32> {
        let output = Command::new("ps").args(["-xww", "-o", "pid=,args="]).stderr(Stdio::null()).output().ok()?;
        default_chrome_pid(&String::from_utf8_lossy(&output.stdout))
    }

    /// The default-profile Chrome, started (without a window of its own) when it is not running.
    fn running_chrome() -> Result<u32, String> {
        if let Some(pid) = chrome_pid() { return Ok(pid); }
        if !crate::system::chrome_installed() { return Err("Google Chrome is not installed".into()); }
        let started = Command::new("open").args(["-na", "Google Chrome", "--args", "--no-startup-window"])
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|status| status.success());
        if !started { return Err("Google Chrome did not start".into()); }
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            if let Some(pid) = chrome_pid() { return Ok(pid); }
            std::thread::sleep(Duration::from_millis(250));
        }
        Err("Google Chrome did not start in 15 seconds".into())
    }

    /// AEDesc as AEDataModel.h declares it, under `#pragma pack(push, 2)`.
    #[repr(C, packed(2))]
    struct AeDesc { descriptor_type: u32, data_handle: *mut std::ffi::c_void }

    #[link(name = "CoreServices", kind = "framework")]
    unsafe extern "C" {
        fn AECreateDesc(type_code: u32, data: *const std::ffi::c_void, size: isize, result: *mut AeDesc) -> i16;
        fn AEDisposeDesc(desc: *mut AeDesc) -> i16;
        fn AEDeterminePermissionToAutomateTarget(target: *const AeDesc, event_class: u32, event_id: u32, ask: u8) -> i32;
    }

    const TYPE_KERNEL_PROCESS_ID: u32 = u32::from_be_bytes(*b"kpid");
    const TYPE_WILD_CARD: u32 = u32::from_be_bytes(*b"****");
    const NOT_PERMITTED: i32 = -1743;

    /// Whether this app may control Chrome `pid`, asking the person when they have not answered yet (this waits for
    /// the answer). Off the main thread only.
    fn may_automate(pid: u32) -> Result<(), String> {
        let pid = pid as i32;
        let mut target = AeDesc { descriptor_type: 0, data_handle: std::ptr::null_mut() };
        // Safety: the descriptor is made from a pid that lives on the stack for the call and disposed of after.
        let mut check = || unsafe {
            let made = AECreateDesc(TYPE_KERNEL_PROCESS_ID, (&pid as *const i32).cast(), std::mem::size_of::<i32>() as isize, &mut target);
            if made != 0 { return Err::<i32, String>(format!("AECreateDesc: {made}")); }
            let status = AEDeterminePermissionToAutomateTarget(&target, TYPE_WILD_CARD, TYPE_WILD_CARD, 1);
            AEDisposeDesc(&mut target);
            Ok(status)
        };
        // Chrome started a moment ago may not take questions yet: ask again for a few seconds.
        let started = Instant::now();
        let status = loop {
            let status: i32 = check()?;
            if !ask_again(status, started.elapsed()) { break status; }
            std::thread::sleep(PERMISSION_WAIT.1);
        };
        match status {
            0 => Ok(()),
            NOT_PERMITTED => Err("not allowed to control Google Chrome (System Settings > Privacy & Security > Automation)".into()),
            other => Err(format!("permission to control Google Chrome: OSStatus {other}")),
        }
    }

    /// Asks for the permission at start, so the first ticket does not wait on the question. A Chrome that is not
    /// running cannot be asked about; then the first ticket asks.
    pub fn ask_permission_early() {
        std::thread::spawn(|| {
            if let Some(pid) = chrome_pid() {
                if let Err(error) = may_automate(pid) { eprintln!("sdlc-todo: {error}"); }
            }
        });
    }

    /// Runs one ticket on the worker.
    fn run(url: String, follow: bool) {
        let place = *PLACE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let visible = place.unwrap_or(Frame { x: 0.0, y: 0.0, width: 1440.0, height: 900.0 });
        let mut last = LAST.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        match show(&mut last, &url, follow, visible) {
            Ok(()) => RECOVER.store(false, Ordering::SeqCst),
            Err(Failure::TimedOut) => {
                RECOVER.store(true, Ordering::SeqCst);
                eprintln!("sdlc-todo: Chrome did not answer in {} seconds for {url}; the next click tries again", SCRIPT_LIMIT.as_secs());
            }
            Err(Failure::Failed(error)) if follow => eprintln!("sdlc-todo: the ticket window did not follow to {url} ({error})"),
            Err(Failure::Failed(error)) => {
                eprintln!("sdlc-todo: the ticket could not open in Chrome ({error}); opening it in the default browser");
                crate::system::open_url(&url);
            }
        }
    }

    fn show(last: &mut Option<(u32, i64)>, url: &str, follow: bool, visible: Frame) -> Result<(), Failure> {
        let pid = running_chrome().map_err(Failure::Failed)?;
        may_automate(pid).map_err(Failure::Failed)?;
        let reuse = last.filter(|(owner, _)| *owner == pid).map(|(_, id)| id);
        let mut command = Command::new("osascript");
        command.args(["-l", "JavaScript", "-e", &script(pid, url, reuse, chrome_bounds(visible), follow, RECOVER.load(Ordering::SeqCst))]);
        // A run that times out records no window: the next opening finds it by its address (RECOVER), if it was made.
        let output = output_within(command, SCRIPT_LIMIT)?;
        if !output.status.success() {
            return Err(Failure::Failed(format!("osascript: {}", String::from_utf8_lossy(&output.stderr).trim())));
        }
        let printed = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if follow && printed.is_empty() { return Ok(()); }
        let id = printed.parse::<i64>().map_err(|e| Failure::Failed(format!("osascript gave no window id ({printed:?}): {e}")))?;
        *last = Some((pid, id));
        if follow { return Ok(()); }
        // Only Chrome's ticket window comes forward (no NSApplicationActivateAllWindows): the person's other Chrome
        // windows stay behind the board. Following never takes the keys away from the board.
        use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication};
        if let Some(chrome) = NSRunningApplication::runningApplicationWithProcessIdentifier(pid as i32) {
            #[allow(deprecated)]
            chrome.activateWithOptions(NSApplicationActivationOptions::empty());
        }
        Ok(())
    }

    /// Shows `url` in the ticket window (`follow`: only an open one, left in place), off the calling thread; never
    /// blocks the board. `visible` is the free area of the board's screen.
    pub fn open(url: String, follow: bool, visible: Frame) {
        *PLACE.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(visible);
        PENDING.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push(url, follow);
        // One worker at a time: while one runs (a slow Chrome, the permission question) it picks this request up.
        if !RUNNING.load(Ordering::SeqCst) { std::thread::spawn(|| drain(&PENDING, &RUNNING, run)); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounds_dock_left_at_45_percent_in_top_left_coordinates() {
        // A 1920×1080 main screen whose menu bar takes 31 points.
        assert_eq!(chrome_bounds(Frame { x: 0.0, y: 31.0, width: 1920.0, height: 1049.0 }), [0, 31, 864, 1049]);
        // A display to the left of the main one, its top 148 points lower.
        assert_eq!(chrome_bounds(Frame { x: -1920.0, y: 148.0, width: 1920.0, height: 1080.0 }), [-1920, 148, 864, 1080]);
    }

    #[test]
    fn the_url_is_a_quoted_string_whatever_it_holds() {
        let text = script(4242, r#"https://x.atlassian.net/browse/A-1?q="a"\b"#, None, [0, 31, 864, 1049], false, false);
        assert!(text.contains(r#"const url = "https://x.atlassian.net/browse/A-1?q=\"a\"\\b";"#), "{text}");
        // A line break or a quote cannot end the string and start a statement.
        let text = script(4242, "https://e.x/\");chrome.quit();(\"\n", None, [0, 0, 1, 1], false, false);
        assert!(text.contains(r#"const url = "https://e.x/\");chrome.quit();(\"\n";"#), "{text}");
        // The URL appears only as that literal; the rest of the script refers to it by name.
        assert!(text.contains("if (win.activeTab.url() !== url) { win.activeTab.url = url; }"));
        assert_eq!(text.matches("chrome.quit").count(), 1);
        assert!(text.starts_with("(() => {\nconst chrome = Application(4242);\n"));
        assert!(text.contains("win.bounds = { x: 0, y: 0, width: 1, height: 1 };"));
    }

    const LOOKUP: &str = "each.activeTab.url() === url";

    #[test]
    fn opening_reuses_the_last_window_else_makes_one_and_looks_by_address_only_to_recover() {
        let reused = script(1, "https://e.x/", Some(1600315930), [0, 0, 1, 1], false, false);
        assert!(reused.contains("const reuse = 1600315930;") && reused.contains("chrome.windows.byId(reuse)"));
        assert!(reused.contains("if (win === null) { win = chrome.Window().make(); }"));
        assert!(!reused.contains(LOOKUP), "no recovery: a window of the person's own on the ticket is not taken");
        assert!(script(1, "https://e.x/", None, [0, 0, 1, 1], false, false).contains("const reuse = null;"));
        // After a timed-out run: the remembered window, then one on the ticket (ours, made by that run), then a new one.
        let recovering = script(1, "https://e.x/", Some(7), [0, 0, 1, 1], false, true);
        let at = |needle: &str| recovering.find(needle).unwrap_or_else(|| panic!("{needle} in {recovering}"));
        assert!(at("chrome.windows.byId(reuse)") < at(LOOKUP) && at(LOOKUP) < at("win = chrome.Window().make()"));
        assert!(recovering.trim_end().ends_with("return String(win.id());\n})()"));
    }

    #[test]
    fn following_uses_only_the_remembered_window_and_leaves_it_in_place() {
        for recover in [false, true] {
            let follow = script(1, "https://e.x/", Some(7), [0, 0, 1, 1], true, recover);
            assert!(follow.contains("const follow = true;"));
            assert!(!follow.contains(LOOKUP), "following never looks for a window by its address (recover {recover})");
            let at = |needle: &str| follow.find(needle).unwrap_or_else(|| panic!("{needle}"));
            assert!(at("chrome.windows.byId(reuse)") < at("if (win === null && follow) { return \"\"; }"));
            assert!(at("if (win === null && follow) { return \"\"; }") < at("win = chrome.Window().make()"));
            assert!(at("if (!follow) {") < at("win.bounds =") && at("win.bounds =") < at("win.index = 1;"));
        }
    }

    #[test]
    fn a_just_started_chrome_is_asked_again_for_five_seconds() {
        use std::time::Duration;
        assert!(ask_again(PROC_NOT_FOUND, Duration::ZERO));
        assert!(ask_again(PROC_NOT_FOUND, Duration::from_millis(4750)));
        assert!(!ask_again(PROC_NOT_FOUND, Duration::from_secs(5)), "then it gives up and the ticket falls back");
        // Any other answer is final: allowed, not allowed (-1743), or another error.
        for status in [0, -1743, -1744, -50] { assert!(!ask_again(status, Duration::ZERO), "{status}"); }
        assert_eq!(PERMISSION_WAIT.1, Duration::from_millis(250));
    }

    #[test]
    fn one_worker_drains_every_request_including_those_that_come_while_it_runs() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Mutex;
        let (pending, running) = (Mutex::new(Pending::default()), AtomicBool::new(false));
        pending.lock().unwrap().push("https://e.x/1".into(), false);
        let mut ran = Vec::new();
        let worked = drain(&pending, &running, |url, follow| {
            // A second worker started now (a j while the permission question is up) leaves the request to this one.
            assert!(!drain(&pending, &running, |_, _| panic!("a second worker ran")));
            if url.ends_with("/1") { pending.lock().unwrap().push("https://e.x/2".into(), true); pending.lock().unwrap().push("https://e.x/3".into(), true); }
            ran.push((url, follow));
        });
        assert!(worked);
        assert_eq!(ran, [("https://e.x/1".to_string(), false), ("https://e.x/3".to_string(), true)], "the newest of those that waited");
        assert!(!running.load(Ordering::SeqCst), "the flag is cleared once nothing waits");
        assert_eq!(pending.lock().unwrap().take(), None);
        // With nothing waiting it stops at once, and the next request starts a worker again.
        assert!(drain(&pending, &running, |_, _| panic!("nothing waits")) && !running.load(Ordering::SeqCst));
    }

    #[test]
    fn waiting_tickets_merge_into_the_newest_and_open_if_any_opened() {
        let mut pending = Pending::default();
        assert_eq!(pending.take(), None);
        pending.push("https://e.x/1".into(), true);
        pending.push("https://e.x/2".into(), true);
        assert_eq!(pending.take(), Some(("https://e.x/2".into(), true)), "selections only: a follow to the newest");
        assert_eq!(pending.take(), None, "taken once");
        // A click, then a selection before Chrome answered: the newest ticket, and the window is still made.
        pending.push("https://e.x/A".into(), false);
        pending.push("https://e.x/B".into(), true);
        assert_eq!(pending.take(), Some(("https://e.x/B".into(), false)));
        pending.push("https://e.x/C".into(), true);
        pending.push("https://e.x/D".into(), false);
        assert_eq!(pending.take(), Some(("https://e.x/D".into(), false)));
    }

    #[cfg(unix)]
    #[test]
    fn a_command_that_does_not_answer_in_time_is_stopped() {
        use std::time::{Duration, Instant};
        let mut quick = std::process::Command::new("sh");
        quick.args(["-c", "echo 42"]);
        let output = output_within(quick, Duration::from_secs(5)).unwrap();
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "42");
        let mut slow = std::process::Command::new("sleep");
        slow.arg("30");
        let started = Instant::now();
        assert_eq!(output_within(slow, Duration::from_millis(200)).unwrap_err(), Failure::TimedOut);
        // A program that cannot start is a failure, not a timeout.
        let missing = std::process::Command::new("/nonexistent/sdlc-todo-osascript");
        assert!(matches!(output_within(missing, Duration::from_secs(1)), Err(Failure::Failed(_))));
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn the_default_profile_chrome_is_the_one_without_its_own_data_dir() {
        let ps = "  8473 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --allow-pre-commit-input --user-data-dir=/tmp/pw\n\
            61550 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper --type=gpu-process\n\
            46141 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new\n\
            59744 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --app=http://127.0.0.1:61620/#t=x&app=1\n";
        assert_eq!(default_chrome_pid(ps), Some(59744));
        assert_eq!(default_chrome_pid("  8473 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/tmp/pw\n"), None);
        assert_eq!(default_chrome_pid("  77 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n"), Some(77));
    }
}
