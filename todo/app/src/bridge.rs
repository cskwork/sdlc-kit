//! What the board page may ask of the shell (`window.todoApp`, board.rs). The capability lets only the current
//! server's origin in the board window call these; each call checks that again, because an earlier server's origin
//! stays allowed for the life of the process.
use crate::{board, fonts, links, lock, prefs, server::Session, system, Shell};
use serde::Serialize;
use std::collections::BTreeMap;
use tauri::{AppHandle, State, WebviewWindow};

pub const COMMANDS: [&str; 5] = ["ticket", "app_state", "save_memo", "save_view", "open_terminal"];

/// A memo's longest text, in bytes.
const MEMO_LIMIT: usize = 64 * 1024;

fn from_board(window: &WebviewWindow, shell: &Shell) -> Result<(), String> {
    let origin = lock(&shell.shared).session.as_ref().map(Session::origin).unwrap_or_default();
    let here = window.url().map_err(|e| e.to_string())?;
    if window.label() == board::LABEL && links::within(here.as_str(), &origin) { Ok(()) } else { Err("not the board".into()) }
}

/// Shows a ticket beside the board (`follow`: moves only an open ticket window).
#[tauri::command(async)]
pub fn ticket(app: AppHandle, window: WebviewWindow, shell: State<'_, Shell>, url: String, follow: bool) -> Result<(), String> {
    from_board(&window, &shell)?;
    links::ticket(&url)?;
    board::open_ticket(&app, &url, follow);
    Ok(())
}

#[derive(Serialize)]
pub struct Font { name: &'static str, file: String }

/// The person's own settings and memos, for the board to show.
#[derive(Serialize)]
pub struct AppState {
    memos: BTreeMap<String, String>,
    size: u32,
    sizes: (u32, u32),
    font: String,
    fonts: Vec<Font>,
    /// Whether `open_terminal` can work on this system.
    terminal: bool,
    /// Whether an open ticket window follows the selection on this system.
    follows: bool,
    /// Why the settings file could not be read, when it could not (it was set aside, not overwritten).
    error: Option<String>,
}

#[tauri::command(async)]
pub fn app_state(window: WebviewWindow, shell: State<'_, Shell>) -> Result<AppState, String> {
    from_board(&window, &shell)?;
    let fonts: Vec<Font> = fonts::installed().into_iter().map(|(name, file)| Font { name, file }).collect();
    let prefs = lock(&shell.prefs).clone();
    // Only a font found on this machine leads; a file that is gone falls back to the board's own order.
    let font = if fonts.iter().any(|font| font.file == prefs.font) { prefs.font.clone() } else { String::new() };
    Ok(AppState { memos: prefs.memos.clone(), size: prefs.size(), sizes: prefs::SIZE, font, fonts,
        terminal: system::has_terminal(), follows: cfg!(target_os = "macos"), error: lock(&shell.prefs_error).clone() })
}

/// Keeps the person's memo on an item in the app's own file; an empty one is dropped.
#[tauri::command(async)]
pub fn save_memo(window: WebviewWindow, shell: State<'_, Shell>, id: String, text: String) -> Result<(), String> {
    from_board(&window, &shell)?;
    if text.len() > MEMO_LIMIT || id.len() > 80 || id.is_empty() { return Err(format!("a memo may hold {MEMO_LIMIT} bytes")); }
    let model = lock(&shell.shared).model.clone();
    let done: Vec<&str> = model.items.iter().filter(|item| item.done).map(|item| item.id.as_str()).collect();
    let mut prefs = lock(&shell.prefs);
    let mut next = prefs.clone();
    next.set_memo(&id, &text, &done);
    next.save(&shell.prefs_file)?;
    *prefs = next;
    Ok(())
}

/// Keeps the text size (percent) and the font file, one of those `app_state` listed or none.
#[tauri::command(async)]
pub fn save_view(window: WebviewWindow, shell: State<'_, Shell>, size: u32, font: String) -> Result<(), String> {
    from_board(&window, &shell)?;
    if !font.is_empty() && !fonts::installed().iter().any(|(_, file)| *file == font) { return Err("unknown font".into()); }
    let mut prefs = lock(&shell.prefs);
    let mut next = prefs.clone();
    next.set_size(size);
    next.font = font;
    next.save(&shell.prefs_file)?;
    *prefs = next;
    Ok(())
}

/// Opens a terminal with the item's own `run` command typed, not run. The page names the item; the command is the one
/// the server sent, so the page cannot type anything else. False where this system cannot.
#[tauri::command(async)]
pub fn open_terminal(window: WebviewWindow, shell: State<'_, Shell>, id: String) -> Result<bool, String> {
    from_board(&window, &shell)?;
    let command = lock(&shell.shared).model.items.iter().find(|item| item.id == id && !item.done).map(|item| item.run.clone()).unwrap_or_default();
    if command.is_empty() { return Err("the item has no command".into()); }
    Ok(system::open_terminal(&command))
}
