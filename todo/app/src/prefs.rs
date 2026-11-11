//! The human's own view settings and memos, kept beside the session file. Nothing here reaches
//! todo.md, the server or an agent.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

/// How far the window's contents scale.
pub const ZOOM: (f32, f32) = (0.8, 2.0);

#[derive(Clone, Serialize, Deserialize)]
pub struct Prefs {
    /// Scale of everything in the window.
    #[serde(default = "default_zoom")]
    pub zoom: f32,
    /// The font file that leads; empty means the built-in one.
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

impl Prefs {
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
