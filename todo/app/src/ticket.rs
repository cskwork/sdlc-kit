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

/// The process id of Chrome's default-profile instance in `ps -axww -o pid=,args=` output: the main Chrome binary
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
/// that window at `bounds` in front of Chrome's other windows, and prints its id for the next ticket.
pub fn script(pid: u32, url: &str, reuse: Option<i64>, bounds: [i64; 4]) -> String {
    let [x, y, width, height] = bounds;
    let reuse = reuse.map_or("null".to_string(), |id| id.to_string());
    format!(r#"const chrome = Application({pid});
const reuse = {reuse};
let win = null;
if (reuse !== null) {{ try {{ const found = chrome.windows.byId(reuse); found.id(); win = found; }} catch (e) {{}} }}
if (win === null) {{ win = chrome.Window().make(); }}
win.activeTab.url = {url};
win.bounds = {{ x: {x}, y: {y}, width: {width}, height: {height} }};
win.index = 1;
win.id();
"#, url = js_string(url))
}

#[cfg(target_os = "macos")]
pub use mac::open;

#[cfg(target_os = "macos")]
mod mac {
    use super::{chrome_bounds, default_chrome_pid, script};
    use crate::board::Frame;
    use std::process::{Command, Stdio};
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    /// The Chrome instance and window the last ticket went to. Held while a ticket opens, so two clicks in a row
    /// make one window, not two.
    static LAST: Mutex<Option<(u32, i64)>> = Mutex::new(None);

    fn chrome_pid() -> Option<u32> {
        let output = Command::new("ps").args(["-axww", "-o", "pid=,args="]).stderr(Stdio::null()).output().ok()?;
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

    fn run(url: &str, visible: Frame, main_height: f64) -> Result<(), String> {
        let mut last = LAST.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let pid = running_chrome()?;
        let reuse = last.filter(|(owner, _)| *owner == pid).map(|(_, id)| id);
        let output = Command::new("osascript").args(["-l", "JavaScript", "-e", &script(pid, url, reuse, chrome_bounds(visible, main_height))])
            .stdin(Stdio::null()).output().map_err(|e| format!("osascript: {e}"))?;
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
        Ok(())
    }

    /// Shows `url` in the ticket window, off the calling thread; never blocks the board. `visible` is the visible
    /// area of the board's screen and `main_height` the main screen's full height, both read on the main thread.
    pub fn open(url: String, visible: Frame, main_height: f64) {
        std::thread::spawn(move || {
            if let Err(error) = run(&url, visible, main_height) {
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
        assert!(text.contains(r#"win.activeTab.url = "https://x.atlassian.net/browse/A-1?q=\"a\"\\b";"#), "{text}");
        // A line break or a quote cannot end the string and start a statement.
        let text = script(4242, "https://e.x/\");chrome.quit();(\"\n", None, [0, 0, 1, 1]);
        assert!(text.contains(r#"win.activeTab.url = "https://e.x/\");chrome.quit();(\"\n";"#), "{text}");
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
