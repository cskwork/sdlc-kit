//! The human's own view settings and memos, kept beside the session file. Nothing here reaches
//! todo.md, the server or an agent.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

/// How far `zoom` may go.
pub const ZOOM: (f32, f32) = (0.8, 2.0);

#[derive(Clone, Serialize, Deserialize)]
pub struct Prefs {
    /// Text size. 1.15 is the board's ordinary size: the list window of versions up to 3.7 drew smaller base text and
    /// opened at 1.15, so a size saved there means the same here.
    #[serde(default = "default_zoom")]
    pub zoom: f32,
    /// The font file that leads; empty means the board's own order.
    #[serde(default)]
    pub font: String,
    /// Memos by item id.
    #[serde(default)]
    pub memos: BTreeMap<String, String>,
}

fn default_zoom() -> f32 { 1.15 }

impl Default for Prefs {
    fn default() -> Prefs { Prefs { zoom: default_zoom(), font: String::new(), memos: BTreeMap::new() } }
}

/// The smallest and largest text size the board offers, in percent.
pub const SIZE: (u32, u32) = (80, 160);

impl Prefs {
    /// The text size in percent of the board's ordinary one, in whole tens.
    pub fn size(&self) -> u32 { ((f64::from(self.zoom / default_zoom()) * 10.0).round() as u32 * 10).clamp(SIZE.0, SIZE.1) }
    pub fn set_size(&mut self, percent: u32) { self.zoom = percent.clamp(SIZE.0, SIZE.1) as f32 / 100.0 * default_zoom(); }

    /// Keeps the person's words on an item; empty ones go. Memos of items the list shows as done (`done`) go too. An
    /// id the list does not have is kept: ids change with title edits and items can be briefly absent, and a lost
    /// memo cannot come back.
    pub fn set_memo(&mut self, id: &str, text: &str, done: &[&str]) {
        self.memos.insert(id.to_string(), text.to_string());
        self.memos.retain(|id, text| !text.trim().is_empty() && !done.contains(&id.as_str()));
    }

    /// Reads the file; only a missing one means defaults. A file that cannot be read or does not parse
    /// is set aside as `<file>.bad` (the next save would otherwise overwrite its memos) and reported.
    pub fn load(file: &Path) -> (Prefs, Option<String>) {
        let error = match std::fs::read_to_string(file) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return (Prefs::default(), None),
            Err(error) => error.to_string(),
            Ok(text) => match serde_json::from_str::<Prefs>(&text) {
                Ok(mut prefs) => { prefs.zoom = prefs.zoom.clamp(ZOOM.0, ZOOM.1); return (prefs, None); }
                Err(error) => error.to_string(),
            },
        };
        let aside = file.with_extension("json.bad");
        let moved = match std::fs::rename(file, &aside) { Ok(()) => format!(" -> {}", aside.display()), Err(e) => format!(" (not set aside: {e})") };
        (Prefs::default(), Some(format!("{}: {error}{moved}", file.display())))
    }

    /// Writes a temporary file beside it and renames it over the real one, so a crash mid-write
    /// leaves the old file whole rather than half-written JSON.
    pub fn save(&self, file: &Path) -> Result<(), String> {
        let text = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        let mut name = file.as_os_str().to_owned();
        name.push(".tmp");
        let temp = std::path::PathBuf::from(name);
        std::fs::write(&temp, text).map_err(|e| format!("{}: {e}", temp.display()))?;
        // Memos are the human's own words; keep the file to them, like the session file.
        #[cfg(unix)]
        { use std::os::unix::fs::PermissionsExt; let _ = std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o600)); }
        std::fs::rename(&temp, file).map_err(|e| format!("{}: {e}", file.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_the_egui_list_wrote_keeps_its_memos_font_and_size() {
        let mut prefs: Prefs = serde_json::from_str(r#"{"zoom":1.15,"font":"/Library/Fonts/NanumGothic.ttf","memos":{"abc123":"ask QA","gone":"kept"}}"#).unwrap();
        assert_eq!((prefs.size(), prefs.memos.len()), (100, 2));
        prefs.set_memo("abc123", "ask QA first", &[]);
        prefs.set_memo("new", "x", &["other"]);
        assert_eq!(prefs.memos.keys().collect::<Vec<_>>(), ["abc123", "gone", "new"]);
        // Emptied, or on an item the list shows as done: dropped.
        prefs.set_memo("new", "  ", &["abc123"]);
        assert_eq!(prefs.memos.keys().collect::<Vec<_>>(), ["gone"]);
        for percent in [80, 90, 100, 130, 160] { prefs.set_size(percent); assert_eq!(prefs.size(), percent); }
        prefs.set_size(900);
        assert_eq!(prefs.size(), 160);
        prefs.zoom = 1.4;
        assert_eq!(prefs.size(), 120);
    }

    #[test]
    fn saves_and_loads_and_sets_a_broken_file_aside() {
        let dir = std::env::temp_dir().join(format!("sdlc-todo-prefs-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("todo-app.json");
        assert!(Prefs::load(&file).1.is_none());
        let mut prefs = Prefs::default();
        prefs.memos.insert("abc123".into(), "ask QA first".into());
        prefs.zoom = 9.0;
        prefs.save(&file).unwrap();
        assert!(!dir.join("todo-app.json.tmp").exists());
        let (loaded, error) = Prefs::load(&file);
        assert!(error.is_none());
        assert_eq!(loaded.memos["abc123"], "ask QA first");
        assert_eq!(loaded.zoom, ZOOM.1);
        std::fs::write(&file, "{ not json").unwrap();
        let (fallback, error) = Prefs::load(&file);
        assert!(error.is_some() && fallback.memos.is_empty());
        assert!(dir.join("todo-app.json.bad").is_file() && !file.exists());
        // A file that is there but cannot be read is not "no file": it is reported and set aside too.
        std::fs::remove_file(dir.join("todo-app.json.bad")).unwrap();
        std::fs::create_dir(&file).unwrap();
        let (_, error) = Prefs::load(&file);
        assert!(error.is_some() && dir.join("todo-app.json.bad").is_dir() && !file.exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
