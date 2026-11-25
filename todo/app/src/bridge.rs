//! What the board page may ask of the shell (`window.todoApp`, board.rs). The capability lets only the current
//! server's origin in the board window call these; each call checks that again, because an earlier server's origin
//! stays allowed for the life of the process.
use crate::model::Model;
use crate::{board, fonts, links, lock, prefs, system, Shell};
use serde::Serialize;
use std::collections::BTreeMap;
use tauri::{AppHandle, State, WebviewWindow};

pub const COMMANDS: [&str; 7] = ["ticket", "app_state", "save_memo", "save_view", "open_terminal", "unsent", "quit"];

/// A memo's longest text, in bytes.
const MEMO_LIMIT: usize = 64 * 1024;

/// How far a call is trusted.
#[derive(Clone, Copy, PartialEq)]
enum Trust {
    /// The page this app loaded: it may hand things in, also after its server was lost or replaced.
    Page,
    /// And its server still answers this app: it may also be told things and have things done.
    Granted,
}

fn check(window: &WebviewWindow, shell: &Shell, proof: &str, trust: Trust) -> Result<(), String> {
    // A page that asks has come up, so the window has an address.
    let here = window.url().map_err(|e| e.to_string())?;
    let shared = lock(&shell.shared);
    let ok = match trust { Trust::Page => shared.is_page(here.as_str(), proof), Trust::Granted => shared.is_granted(here.as_str(), proof) };
    if window.label() == board::LABEL && ok { Ok(()) } else { Err("not the board".into()) }
}

/// Shows a ticket beside the board (`follow`: moves only an open ticket window).
#[tauri::command(async)]
pub fn ticket(app: AppHandle, window: WebviewWindow, shell: State<'_, Shell>, proof: String, url: String, follow: bool) -> Result<(), String> {
    check(&window, &shell, &proof, Trust::Granted)?;
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
    /// What the page before this one still held (board.rs); told once.
    carried: Option<serde_json::Value>,
    /// A view picked on the tray while this page loaded.
    view: Option<&'static str>,
}

#[tauri::command(async)]
pub fn app_state(window: WebviewWindow, shell: State<'_, Shell>, proof: String) -> Result<AppState, String> {
    check(&window, &shell, &proof, Trust::Granted)?;
    let fonts: Vec<Font> = fonts::installed().into_iter().map(|(name, file)| Font { name, file }).collect();
    let prefs = lock(&shell.prefs).clone();
    // Only a font found on this machine leads; a file that is gone falls back to the board's own order.
    let font = if fonts.iter().any(|font| font.file == prefs.font) { prefs.font.clone() } else { String::new() };
    Ok(AppState { memos: prefs.memos.clone(), size: prefs.size(), sizes: prefs::SIZE, font, fonts,
        terminal: system::has_terminal(), follows: cfg!(target_os = "macos"), error: lock(&shell.prefs_error).clone(),
        carried: lock(&shell.carried).take(), view: lock(&shell.picked).take().map(board::View::name) })
}

/// Keeps the person's memo on an item in the app's own file; an empty one is dropped.
#[tauri::command(async)]
pub fn save_memo(window: WebviewWindow, shell: State<'_, Shell>, proof: String, id: String, text: String) -> Result<(), String> {
    check(&window, &shell, &proof, Trust::Page)?;
    if id.is_empty() || id.len() > 200 { return Err("not an item".into()); }
    let model = lock(&shell.shared).model.clone();
    let done: Vec<&str> = model.items.iter().filter(|item| item.done).map(|item| item.id.as_str()).collect();
    let mut prefs = lock(&shell.prefs);
    // One written longer before there was a limit may still be edited down.
    if text.len() > prefs.memos.get(&id).map_or(0, String::len).max(MEMO_LIMIT) { return Err(format!("a memo may hold {MEMO_LIMIT} bytes")); }
    let mut next = prefs.clone();
    next.set_memo(&id, &text, &done);
    next.save(&shell.prefs_file)?;
    *prefs = next;
    Ok(())
}

/// Keeps the text size (percent) and the font file, one of those `app_state` listed or none.
#[tauri::command(async)]
pub fn save_view(window: WebviewWindow, shell: State<'_, Shell>, proof: String, size: u32, font: String) -> Result<(), String> {
    check(&window, &shell, &proof, Trust::Page)?;
    if !font.is_empty() && !fonts::installed().iter().any(|(_, file)| *file == font) { return Err("unknown font".into()); }
    let mut prefs = lock(&shell.prefs);
    let mut next = prefs.clone();
    next.set_size(size);
    next.font = font;
    next.save(&shell.prefs_file)?;
    *prefs = next;
    Ok(())
}

/// The item's command, when it is still the one the page shows.
fn shown_command<'a>(model: &'a Model, id: &str, shown: &str) -> Result<&'a str, String> {
    let command = model.items.iter().find(|item| item.id == id && !item.done).map(|item| item.run.as_str()).unwrap_or_default();
    if command.is_empty() || command != shown { return Err("changed".into()); }
    Ok(command)
}

/// Opens a terminal with the item's own `run` command typed, not run. The page names the item and the command it shows;
/// the command typed is the one the server sent, and only when both are the same. False where this system cannot.
#[tauri::command(async)]
pub fn open_terminal(window: WebviewWindow, shell: State<'_, Shell>, proof: String, id: String, command: String) -> Result<bool, String> {
    check(&window, &shell, &proof, Trust::Granted)?;
    let model = lock(&shell.shared).model.clone();
    Ok(system::open_terminal(shown_command(&model, &id, &command)?))
}

/// Whether the page holds something unsent: asked about before quitting.
#[tauri::command(async)]
pub fn unsent(window: WebviewWindow, shell: State<'_, Shell>, proof: String, unsent: bool) -> Result<(), String> {
    check(&window, &shell, &proof, Trust::Page)?;
    lock(&shell.shared).unsent = unsent;
    Ok(())
}

/// The person chose to quit although something is unsent.
#[tauri::command(async)]
pub fn quit(app: AppHandle, window: WebviewWindow, shell: State<'_, Shell>, proof: String) -> Result<(), String> {
    check(&window, &shell, &proof, Trust::Page)?;
    crate::quit::end(&app);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_command_on_screen_is_typed() {
        let mut model: Model = serde_json::from_str(r#"{"items":[{"id":"1","title":"t","run":"vpn login","turn":{"actor":"you","kind":"answer"}}]}"#).unwrap();
        assert_eq!(shown_command(&model, "1", "vpn login"), Ok("vpn login"));
        for (id, shown) in [("1", "vpn logout"), ("1", ""), ("2", "vpn login")] { assert!(shown_command(&model, id, shown).is_err(), "{id} {shown}"); }
        model.items[0].run = "rm -rf x".into();
        assert!(shown_command(&model, "1", "vpn login").is_err(), "it changed since");
        model.items[0].run.clear();
        assert!(shown_command(&model, "1", "").is_err());
    }
}
