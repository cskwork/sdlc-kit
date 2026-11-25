//! Where the board window stands: its saved place, held on a screen. Pure, so it is tested on every system.
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// A frame on the desktop: origin at the main screen's top left, y growing downwards. Points on macOS, whose screens
/// share one point space; pixels elsewhere, where they share one pixel space (see board.rs).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Frame {
    fn overlap(&self, other: &Frame) -> f64 {
        let width = (self.x + self.width).min(other.x + other.width) - self.x.max(other.x);
        let height = (self.y + self.height).min(other.y + other.height) - self.y.max(other.y);
        width.max(0.0) * height.max(0.0)
    }
}

/// The smallest board window, in points: the board's narrow layout still fits.
pub const BOARD_MIN: (f64, f64) = (640.0, 480.0);

/// Part of the screen the ticket window takes at its left edge, as board.js asks of its popup (v3.3.4).
const TICKET_SHARE: f64 = 0.45;

/// The ticket window: the left edge of the screen's free area, 45% of its width, its full height.
pub fn ticket_frame(screen: Frame) -> Frame {
    Frame { x: screen.x, y: screen.y, width: (screen.width * TICKET_SHARE).round(), height: screen.height }
}

/// The board window: the saved frame, held inside the free area of the screen it overlaps most (no bigger than that
/// area, its title bar inside it), while it is big enough (`min`) and still touches a screen (a display may have gone
/// since); otherwise the rest of the main screen beside the ticket window. `screens` are the free areas, the main
/// screen first.
pub fn board_frame(saved: Option<Frame>, screens: &[Frame], min: (f64, f64)) -> Frame {
    let sound = |frame: &Frame| [frame.x, frame.y, frame.width, frame.height].iter().all(|v| v.is_finite())
        && frame.width >= min.0 && frame.height >= min.1;
    if let Some(frame) = saved.filter(sound) {
        let best = screens.iter().filter(|screen| frame.overlap(screen) > 0.0).max_by(|a, b| frame.overlap(a).total_cmp(&frame.overlap(b)));
        if let Some(screen) = best { return clamp(frame, *screen); }
    }
    let main = screens.first().copied().unwrap_or(Frame { x: 0.0, y: 0.0, width: 1440.0, height: 900.0 });
    let width = (main.width - ticket_frame(main).width).max(min.0.min(main.width));
    Frame { x: main.x + main.width - width, y: main.y, width, height: main.height }
}

/// `frame` moved and shrunk to fit inside `screen`.
fn clamp(frame: Frame, screen: Frame) -> Frame {
    let (width, height) = (frame.width.min(screen.width), frame.height.min(screen.height));
    Frame {
        x: frame.x.clamp(screen.x, screen.x + screen.width - width),
        y: frame.y.clamp(screen.y, screen.y + screen.height - height),
        width,
        height,
    }
}

/// The saved place, in `todo-app-window.json` beside the app's `todo-app.json`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct WindowState {
    /// The outer frame, in `Frame`'s coordinates.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<Frame>,
    /// Versions up to 3.7 (macOS only) kept it here with AppKit's origin at the bottom left.
    #[serde(default, skip_serializing)]
    board: Option<Frame>,
}

impl WindowState {
    pub fn of(frame: Frame) -> WindowState { WindowState { window: Some(frame), board: None } }

    /// The saved frame; an older one is turned over with the main screen's height.
    pub fn place(&self, main_height: f64) -> Option<Frame> {
        self.window.or_else(|| self.board.map(|old| Frame { y: main_height - (old.y + old.height), ..old }))
    }

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
        let temp = PathBuf::from(name);
        std::fs::write(&temp, text).map_err(|e| format!("{}: {e}", temp.display()))?;
        std::fs::rename(&temp, file).map_err(|e| format!("{}: {e}", file.display()))
    }
}

/// Numbers events so a delayed action can tell whether a newer one came since (only the last move saves the place).
pub struct Latest(std::sync::atomic::AtomicU64);

impl Latest {
    pub const fn new() -> Latest { Latest(std::sync::atomic::AtomicU64::new(0)) }
    pub fn take(&self) -> u64 { self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1 }
    pub fn is_newest(&self, ticket: u64) -> bool { self.0.load(std::sync::atomic::Ordering::SeqCst) == ticket }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 1512×982 main screen: the free area starts below the menu bar.
    const SCREEN: Frame = Frame { x: 0.0, y: 38.0, width: 1512.0, height: 944.0 };

    fn place(saved: Option<Frame>, screens: &[Frame]) -> Frame { board_frame(saved, screens, BOARD_MIN) }

    #[test]
    fn the_ticket_window_takes_the_left_45_percent_at_full_height() {
        assert_eq!(ticket_frame(SCREEN), Frame { x: 0.0, y: 38.0, width: 680.0, height: 944.0 });
        let left = Frame { x: -1920.0, y: -25.0, width: 1920.0, height: 1055.0 };
        assert_eq!(ticket_frame(left), Frame { x: -1920.0, y: -25.0, width: 864.0, height: 1055.0 });
    }

    #[test]
    fn the_board_keeps_its_saved_place_while_it_is_on_a_screen() {
        let saved = Frame { x: 100.0, y: 90.0, width: 1000.0, height: 700.0 };
        assert_eq!(place(Some(saved), &[SCREEN]), saved);
        // Without a saved place, or with one on a display that is gone or too small to use, it takes the rest of
        // the main screen beside the ticket window.
        let beside = Frame { x: 680.0, y: 38.0, width: 832.0, height: 944.0 };
        assert_eq!(place(None, &[SCREEN]), beside);
        assert_eq!(place(Some(Frame { x: 4000.0, ..saved }), &[SCREEN]), beside);
        assert_eq!(place(Some(Frame { width: 200.0, ..saved }), &[SCREEN]), beside);
        assert_eq!(place(Some(Frame { x: f64::NAN, ..saved }), &[SCREEN]), beside);
        // Windows parks a minimised window far off every screen.
        assert_eq!(place(Some(Frame { x: -32000.0, y: -32000.0, ..saved }), &[SCREEN]), beside);
        // On the second display it was moved to, it stays.
        let other = Frame { x: 1512.0, y: 0.0, width: 1920.0, height: 1080.0 };
        let there = Frame { x: 1700.0, ..saved };
        assert_eq!(place(Some(there), &[SCREEN, other]), there);
    }

    #[test]
    fn a_saved_place_is_held_inside_its_screen() {
        // Huge: no bigger than the screen's free area, and inside it.
        assert_eq!(place(Some(Frame { x: 100.0, y: 50.0, width: 1e9, height: 1e9 }), &[SCREEN]), SCREEN);
        // Off the top: the title bar comes back below the menu bar; x is kept.
        assert_eq!(place(Some(Frame { x: 300.0, y: -200.0, width: 1000.0, height: 700.0 }), &[SCREEN]), Frame { x: 300.0, y: 38.0, width: 1000.0, height: 700.0 });
        // Hanging off the right and bottom edges: pulled in on the screen it overlaps most.
        assert_eq!(place(Some(Frame { x: 1000.0, y: 600.0, width: 1000.0, height: 700.0 }), &[SCREEN]), Frame { x: 512.0, y: 282.0, width: 1000.0, height: 700.0 });
    }

    #[test]
    fn the_minimum_follows_the_screens_scale() {
        let saved = Frame { x: 0.0, y: 0.0, width: 700.0, height: 500.0 };
        let screen = Frame { x: 0.0, y: 0.0, width: 3840.0, height: 2100.0 };
        // 700 pixels at 200% is 350 points: too small to use.
        assert_ne!(board_frame(Some(saved), &[screen], (BOARD_MIN.0 * 2.0, BOARD_MIN.1 * 2.0)), saved);
        assert_eq!(board_frame(Some(saved), &[screen], BOARD_MIN), saved);
    }

    #[test]
    fn only_the_newest_move_saves() {
        let latest = Latest::new();
        let (first, second, third) = (latest.take(), latest.take(), latest.take());
        assert!(!latest.is_newest(first) && !latest.is_newest(second) && latest.is_newest(third));
    }

    #[test]
    fn the_window_state_file_round_trips_and_tolerates_breakage() {
        let dir = std::env::temp_dir().join(format!("sdlc-todo-window-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("todo-app-window.json");
        assert_eq!(WindowState::load(&file), WindowState::default());
        let state = WindowState::of(Frame { x: 680.0, y: 38.0, width: 832.0, height: 944.0 });
        state.save(&file).unwrap();
        assert!(!dir.join("todo-app-window.json.tmp").exists());
        assert_eq!(WindowState::load(&file), state);
        // The format the file keeps, so a person or a later version can read it.
        let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        assert_eq!(json, serde_json::json!({ "window": { "x": 680.0, "y": 38.0, "width": 832.0, "height": 944.0 } }));
        // The place an older version saved: the same spot, measured from the other edge.
        std::fs::write(&file, r#"{ "board": { "x": 680, "y": 0, "width": 832, "height": 944 } }"#).unwrap();
        assert_eq!(WindowState::load(&file).place(982.0), Some(Frame { x: 680.0, y: 38.0, width: 832.0, height: 944.0 }));
        // Fields it does not know and a missing place are fine; broken JSON means the default place.
        std::fs::write(&file, r#"{ "ticket": 1 }"#).unwrap();
        assert_eq!(WindowState::load(&file).place(982.0), None);
        std::fs::write(&file, "{ not json").unwrap();
        assert_eq!(WindowState::load(&file), WindowState::default());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
