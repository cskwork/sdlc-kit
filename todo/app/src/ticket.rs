//! The ticket window: a ticket the board opens shows in the person's own Google Chrome (default profile), where
//! their Jira login already lives, as one window docked at the screen's left edge (45% wide, full height, as board.js
//! v3.3.4 places its popup) and reused for every later ticket. The board window and its panel never move.
//!
//! Chrome is driven with JavaScript for Automation (`osascript -l JavaScript`) addressed by process id, not by name:
//! test browsers started by automation tools also run as "Google Chrome", and a name picks any of them. The default
//! profile's instance is the one started without `--user-data-dir`. macOS asks once for permission to control
//! Chrome. Without Chrome, or when the script fails, the ticket opens in the default browser, unplaced, and the
//! reason is logged.
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

/// The script that shows `url` in Chrome `pid`'s window `reuse` when it is still open, else in a new window, places
/// that window at `bounds` in front of Chrome's other windows, and prints its id for the next ticket. A window already
/// showing `url` is not reloaded: opening the same ticket again only brings it back.
pub fn script(pid: u32, url: &str, reuse: Option<i64>, bounds: [i64; 4]) -> String {
    let [x, y, width, height] = bounds;
    let reuse = reuse.map_or("null".to_string(), |id| id.to_string());
    format!(r#"const chrome = Application({pid});
const url = {url};
const reuse = {reuse};
let win = null;
if (reuse !== null) {{ try {{ const found = chrome.windows.byId(reuse); found.id(); win = found; }} catch (e) {{}} }}
if (win === null) {{ win = chrome.Window().make(); }}
if (win.activeTab.url() !== url) {{ win.activeTab.url = url; }}
win.bounds = {{ x: {x}, y: {y}, width: {width}, height: {height} }};
win.index = 1;
win.id();
"#, url = js_string(url))
}

/// Coalesces ticket requests: each gets a number, and one that finds a newer number taken when its turn comes is
/// dropped, so a burst of clicks ends on the newest ticket instead of queueing every one behind a slow Chrome.
pub struct Latest(std::sync::atomic::AtomicU64);

impl Latest {
    pub const fn new() -> Latest { Latest(std::sync::atomic::AtomicU64::new(0)) }
    pub fn take(&self) -> u64 { self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1 }
    pub fn is_newest(&self, ticket: u64) -> bool { self.0.load(std::sync::atomic::Ordering::SeqCst) == ticket }
}

/// Runs `command` and returns its output, or kills it once `limit` passes (a permission prompt nobody answers, a
/// Chrome that hangs). Its output is a line or two, well inside the pipe buffers it waits on.
pub fn output_within(mut command: std::process::Command, limit: std::time::Duration) -> Result<std::process::Output, String> {
    use std::process::Stdio;
    let mut child = command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
    let deadline = std::time::Instant::now() + limit;
    loop {
        match child.try_wait().map_err(|e| e.to_string())? {
            Some(_) => return child.wait_with_output().map_err(|e| e.to_string()),
            None if std::time::Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("no answer in {} seconds", limit.as_secs_f32()));
            }
            None => std::thread::sleep(std::time::Duration::from_millis(50)),
        }
    }
}

#[cfg(target_os = "macos")]
pub use mac::open;

#[cfg(target_os = "macos")]
mod mac {
    use super::{chrome_bounds, default_chrome_pid, output_within, script, Latest};
    use crate::board::Frame;
    use std::process::{Command, Stdio};
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    /// The Chrome instance and window the last ticket went to. Held while a ticket opens, so two clicks in a row
    /// make one window, not two.
    static LAST: Mutex<Option<(u32, i64)>> = Mutex::new(None);
    static REQUESTS: Latest = Latest::new();
    /// How long Chrome gets to answer before the ticket goes to the default browser.
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

    /// Ok(false) when a newer ticket came while this one waited its turn; that one runs instead.
    fn run(request: u64, url: &str, visible: Frame, main_height: f64) -> Result<bool, String> {
        let mut last = LAST.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if !REQUESTS.is_newest(request) { return Ok(false); }
        let pid = running_chrome()?;
        let reuse = last.filter(|(owner, _)| *owner == pid).map(|(_, id)| id);
        let mut command = Command::new("osascript");
        command.args(["-l", "JavaScript", "-e", &script(pid, url, reuse, chrome_bounds(visible, main_height))]);
        let output = output_within(command, SCRIPT_LIMIT).map_err(|e| format!("osascript: {e}"))?;
        if !output.status.success() {
            return Err(format!("osascript: {}", String::from_utf8_lossy(&output.stderr).trim()));
        }
        let id = String::from_utf8_lossy(&output.stdout).trim().parse::<i64>().map_err(|e| format!("osascript gave no window id: {e}"))?;
        *last = Some((pid, id));
        drop(last);
        // Only Chrome's ticket window comes forward (no NSApplicationActivateAllWindows): the person's other Chrome
        // windows stay behind the board.
        dispatch::Queue::main().exec_async(move || {
            use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication};
            if let Some(chrome) = NSRunningApplication::runningApplicationWithProcessIdentifier(pid as i32) {
                #[allow(deprecated)]
                chrome.activateWithOptions(NSApplicationActivationOptions::empty());
            }
        });
        Ok(true)
    }

    /// Shows `url` in the ticket window, off the calling thread; never blocks the board. `visible` is the visible
    /// area of the board's screen and `main_height` the main screen's full height, both read on the main thread.
    pub fn open(url: String, visible: Frame, main_height: f64) {
        let request = REQUESTS.take();
        std::thread::spawn(move || {
            if let Err(error) = run(request, &url, visible, main_height) {
                eprintln!("sdlc-todo: the ticket could not open in Chrome ({error}); opening it in the default browser");
                crate::open_url(&url);
            }
        });
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
        let text = script(4242, r#"https://x.atlassian.net/browse/A-1?q="a"\b"#, None, [0, 31, 864, 1049]);
        assert!(text.contains(r#"const url = "https://x.atlassian.net/browse/A-1?q=\"a\"\\b";"#), "{text}");
        // A line break or a quote cannot end the string and start a statement.
        let text = script(4242, "https://e.x/\");chrome.quit();(\"\n", None, [0, 0, 1, 1]);
        assert!(text.contains(r#"const url = "https://e.x/\");chrome.quit();(\"\n";"#), "{text}");
        // The URL appears only as that literal; the rest of the script refers to it by name.
        assert!(text.contains("if (win.activeTab.url() !== url) { win.activeTab.url = url; }"));
        assert_eq!(text.matches("chrome.quit").count(), 1);
        assert!(text.starts_with("const chrome = Application(4242);\n"));
        assert!(text.contains("win.bounds = { x: 0, y: 0, width: 1, height: 1 };"));
    }

    #[test]
    fn the_script_reuses_the_last_window_or_makes_one() {
        let new = script(1, "https://e.x/", None, [0, 0, 1, 1]);
        assert!(new.contains("const reuse = null;") && new.contains("chrome.Window().make()"));
        let reused = script(1, "https://e.x/", Some(1600315930), [0, 0, 1, 1]);
        assert!(reused.contains("const reuse = 1600315930;") && reused.contains("chrome.windows.byId(reuse)"));
        // A window closed since then falls through to a new one.
        assert!(reused.contains("if (win === null) { win = chrome.Window().make(); }"));
    }

    #[test]
    fn a_burst_of_tickets_ends_on_the_newest() {
        let latest = Latest::new();
        let (first, second, third) = (latest.take(), latest.take(), latest.take());
        assert!(!latest.is_newest(first) && !latest.is_newest(second) && latest.is_newest(third));
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
        assert!(output_within(slow, Duration::from_millis(200)).is_err());
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
