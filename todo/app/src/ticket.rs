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
use crate::board::{ticket_frame, Frame};

/// Chrome's window bounds for a ticket on the screen whose visible area is `visible` (AppKit points: origin at the
/// main screen's bottom left, y up). Chrome's scripting uses the top-left origin of the main screen, y down, so
/// `main_height` (the main screen's full height) flips it. Returns x, y, width, height in whole points.
pub fn chrome_bounds(visible: Frame, main_height: f64) -> [i64; 4] {
    let frame = ticket_frame(visible);
    let top = main_height - (frame.y + frame.height);
    [frame.x.round() as i64, top.round() as i64, frame.width.round() as i64, frame.height.round() as i64]
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

/// The script for Chrome `pid`: it finds the ticket window (`reuse`, the window the last ticket went to, else a window
/// already showing `url`) and shows `url` there. Opening (`follow` false) makes the window when there is none, places
/// it at `bounds` and puts it in front of Chrome's other windows; following only moves an open window to `url`, where
/// the person left it. A window already showing `url` is not reloaded. It prints the window's id, or nothing when
/// following found no window.
pub fn script(pid: u32, url: &str, reuse: Option<i64>, bounds: [i64; 4], follow: bool) -> String {
    let [x, y, width, height] = bounds;
    let reuse = reuse.map_or("null".to_string(), |id| id.to_string());
    format!(r#"(() => {{
const chrome = Application({pid});
const url = {url};
const reuse = {reuse};
const follow = {follow};
let win = null;
if (reuse !== null) {{ try {{ const found = chrome.windows.byId(reuse); found.id(); win = found; }} catch (e) {{}} }}
if (win === null) {{ for (const each of chrome.windows()) {{ try {{ if (each.activeTab.url() === url) {{ win = each; break; }} }} catch (e) {{}} }} }}
if (win === null && follow) {{ return ""; }}
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

/// The ticket waiting for Chrome. Requests that arrive while one runs are merged: the newest address wins, and the
/// merge opens (makes and brings forward the window) when any of them opened, so a click followed by a selection
/// still shows a window.
#[derive(Debug, Default, PartialEq)]
pub struct Pending(Option<(String, bool)>);

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
    use super::{chrome_bounds, default_chrome_pid, output_within, script, Failure, Pending};
    use crate::board::Frame;
    use std::process::{Command, Stdio};
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    /// The Chrome instance and window the last ticket went to. Held while a ticket runs, so two clicks in a row make
    /// one window, not two.
    static LAST: Mutex<Option<(u32, i64)>> = Mutex::new(None);
    static PENDING: Mutex<Pending> = Mutex::new(Pending(None));
    /// How long Chrome gets to answer. The permission question is asked before this clock starts.
    const SCRIPT_LIMIT: Duration = Duration::from_secs(8);

    fn chrome_pid() -> Option<u32> {
        let output = Command::new("ps").args(["-xww", "-o", "pid=,args="]).stderr(Stdio::null()).output().ok()?;
        default_chrome_pid(&String::from_utf8_lossy(&output.stdout))
    }

    /// The default-profile Chrome, started (without a window of its own) when it is not running.
    fn running_chrome() -> Result<u32, String> {
        if let Some(pid) = chrome_pid() { return Ok(pid); }
        if !crate::chrome_installed() { return Err("Google Chrome is not installed".into()); }
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
        let status = unsafe {
            let made = AECreateDesc(TYPE_KERNEL_PROCESS_ID, (&pid as *const i32).cast(), std::mem::size_of::<i32>() as isize, &mut target);
            if made != 0 { return Err(format!("AECreateDesc: {made}")); }
            let status = AEDeterminePermissionToAutomateTarget(&target, TYPE_WILD_CARD, TYPE_WILD_CARD, 1);
            AEDisposeDesc(&mut target);
            status
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

    /// Runs the waiting ticket, if one still waits (an earlier run may have taken it with newer ones merged in).
    fn run(visible: Frame, main_height: f64) {
        let mut last = LAST.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some((url, follow)) = PENDING.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take() else { return };
        match show(&mut last, &url, follow, visible, main_height) {
            Ok(()) => {}
            Err(Failure::TimedOut) => eprintln!("sdlc-todo: Chrome did not answer in {} seconds for {url}; the next click tries again", SCRIPT_LIMIT.as_secs()),
            Err(Failure::Failed(error)) if follow => eprintln!("sdlc-todo: the ticket window did not follow to {url} ({error})"),
            Err(Failure::Failed(error)) => {
                eprintln!("sdlc-todo: the ticket could not open in Chrome ({error}); opening it in the default browser");
                crate::open_url(&url);
            }
        }
    }

    fn show(last: &mut Option<(u32, i64)>, url: &str, follow: bool, visible: Frame, main_height: f64) -> Result<(), Failure> {
        let pid = running_chrome().map_err(Failure::Failed)?;
        may_automate(pid).map_err(Failure::Failed)?;
        let reuse = last.filter(|(owner, _)| *owner == pid).map(|(_, id)| id);
        let mut command = Command::new("osascript");
        command.args(["-l", "JavaScript", "-e", &script(pid, url, reuse, chrome_bounds(visible, main_height), follow)]);
        // A run that times out records no window: the next one finds it by its address, if it was made.
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
        dispatch::Queue::main().exec_async(move || {
            use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication};
            if let Some(chrome) = NSRunningApplication::runningApplicationWithProcessIdentifier(pid as i32) {
                #[allow(deprecated)]
                chrome.activateWithOptions(NSApplicationActivationOptions::empty());
            }
        });
        Ok(())
    }

    /// Shows `url` in the ticket window (`follow`: only an open one, left in place), off the calling thread; never
    /// blocks the board. `visible` is the visible area of the board's screen and `main_height` the main screen's full
    /// height, both read on the main thread.
    pub fn open(url: String, follow: bool, visible: Frame, main_height: f64) {
        PENDING.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push(url, follow);
        std::thread::spawn(move || run(visible, main_height));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounds_dock_left_at_45_percent_in_chromes_top_left_coordinates() {
        // A 1920×1080 main screen whose menu bar takes 31 points: the visible area is 0,0 1920×1049 in AppKit.
        let main = Frame { x: 0.0, y: 0.0, width: 1920.0, height: 1049.0 };
        assert_eq!(chrome_bounds(main, 1080.0), [0, 31, 864, 1049]);
        // A display to the left of the main one, its top 148 points lower: AppKit y = 1080 - 148 - 1080 = -148.
        let left = Frame { x: -1920.0, y: -148.0, width: 1920.0, height: 1080.0 };
        assert_eq!(chrome_bounds(left, 1080.0), [-1920, 148, 864, 1080]);
    }

    #[test]
    fn the_url_is_a_quoted_string_whatever_it_holds() {
        let text = script(4242, r#"https://x.atlassian.net/browse/A-1?q="a"\b"#, None, [0, 31, 864, 1049], false);
        assert!(text.contains(r#"const url = "https://x.atlassian.net/browse/A-1?q=\"a\"\\b";"#), "{text}");
        // A line break or a quote cannot end the string and start a statement.
        let text = script(4242, "https://e.x/\");chrome.quit();(\"\n", None, [0, 0, 1, 1], false);
        assert!(text.contains(r#"const url = "https://e.x/\");chrome.quit();(\"\n";"#), "{text}");
        // The URL appears only as that literal; the rest of the script refers to it by name.
        assert!(text.contains("if (win.activeTab.url() !== url) { win.activeTab.url = url; }"));
        assert_eq!(text.matches("chrome.quit").count(), 1);
        assert!(text.starts_with("(() => {\nconst chrome = Application(4242);\n"));
        assert!(text.contains("win.bounds = { x: 0, y: 0, width: 1, height: 1 };"));
    }

    #[test]
    fn opening_reuses_the_last_window_then_one_showing_the_ticket_then_makes_one() {
        let new = script(1, "https://e.x/", None, [0, 0, 1, 1], false);
        assert!(new.contains("const reuse = null;") && new.contains("const follow = false;"));
        let reused = script(1, "https://e.x/", Some(1600315930), [0, 0, 1, 1], false);
        assert!(reused.contains("const reuse = 1600315930;") && reused.contains("chrome.windows.byId(reuse)"));
        // In that order: the remembered window, a window already on the ticket (one a timed-out run made), a new one.
        let at = |needle: &str| reused.find(needle).unwrap_or_else(|| panic!("{needle} in {reused}"));
        assert!(at("chrome.windows.byId(reuse)") < at("each.activeTab.url() === url"));
        assert!(at("each.activeTab.url() === url") < at("win = chrome.Window().make()"));
        assert!(reused.contains("if (win === null) { win = chrome.Window().make(); }"));
        assert!(reused.trim_end().ends_with("return String(win.id());\n})()"));
    }

    #[test]
    fn following_moves_only_an_open_window_and_leaves_it_in_place() {
        let follow = script(1, "https://e.x/", Some(7), [0, 0, 1, 1], true);
        assert!(follow.contains("const follow = true;"));
        // No window: nothing is made. Its place and order stay the person's.
        let at = |needle: &str| follow.find(needle).unwrap_or_else(|| panic!("{needle}"));
        assert!(at("if (win === null && follow) { return \"\"; }") < at("win = chrome.Window().make()"));
        assert!(at("if (!follow) {") < at("win.bounds =") && at("win.bounds =") < at("win.index = 1;"));
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
