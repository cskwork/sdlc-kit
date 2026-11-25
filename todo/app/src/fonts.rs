//! The readable fonts with Hangul a person can pick for the board, found by file name.
use std::path::{Path, PathBuf};

/// (file name without spaces, dashes or case; the family name the board's CSS uses).
const KNOWN_FONTS: [(&str, &str); 12] = [
    ("pretendard", "Pretendard"),
    ("applesdgothicneo", "Apple SD Gothic Neo"), ("malgun", "Malgun Gothic"), ("notosanscjk", "Noto Sans CJK KR"),
    ("notosanskr", "Noto Sans KR"), ("nanumgothic", "NanumGothic"), ("nanumsquare", "NanumSquare"),
    ("spoqahansansneo", "Spoqa Han Sans Neo"), ("suit", "SUIT"),
    ("applegothic", "AppleGothic"), ("applemyungjo", "AppleMyungjo"), ("nanummyeongjo", "NanumMyeongjo"),
];

fn family(file: &Path) -> Option<&'static str> {
    let readable = file.extension().and_then(|e| e.to_str()).is_some_and(|e| ["ttf", "otf", "ttc"].contains(&e.to_lowercase().as_str()));
    let stem = file.file_stem()?.to_string_lossy().to_lowercase().replace([' ', '-', '_'], "");
    KNOWN_FONTS.iter().find(|(key, _)| readable && (stem == *key || stem == format!("{key}regular") || stem == format!("{key}variable"))).map(|(_, name)| *name)
}

/// The known fonts found on this machine, as (name, file), in the order above.
pub fn installed() -> Vec<(&'static str, String)> {
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).map(PathBuf::from).unwrap_or_default();
    let dirs: Vec<PathBuf> = if cfg!(target_os = "macos") {
        vec!["/System/Library/Fonts".into(), "/System/Library/Fonts/Supplemental".into(), "/Library/Fonts".into(), home.join("Library/Fonts")]
    } else if cfg!(windows) {
        vec!["C:\\Windows\\Fonts".into(), home.join("AppData\\Local\\Microsoft\\Windows\\Fonts")]
    } else {
        vec!["/usr/share/fonts/opentype/noto".into(), "/usr/share/fonts/noto-cjk".into(), "/usr/share/fonts/google-noto-cjk".into(),
            "/usr/share/fonts/truetype/nanum".into(), home.join(".local/share/fonts"), home.join(".fonts")]
    };
    let mut files: Vec<PathBuf> = dirs.iter().filter_map(|dir| std::fs::read_dir(dir).ok()).flatten().filter_map(|entry| entry.ok().map(|e| e.path())).collect();
    files.sort();
    KNOWN_FONTS.iter().filter_map(|(_, name)| {
        let file = files.iter().find(|file| family(file) == Some(name))?;
        Some((*name, file.to_string_lossy().to_string()))
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fonts_family_comes_from_its_file_name() {
        for (file, name) in [("/f/AppleSDGothicNeo.ttc", "Apple SD Gothic Neo"), ("/f/malgun.ttf", "Malgun Gothic"),
            ("/f/NanumSquare-Regular.otf", "NanumSquare"), ("/f/Pretendard_Variable.ttf", "Pretendard")] {
            assert_eq!(family(Path::new(file)), Some(name), "{file}");
        }
        for file in ["/f/Arial.ttf", "/f/malgunbd.ttf", "/f/NanumGothic.txt", "/f"] { assert_eq!(family(Path::new(file)), None, "{file}"); }
    }
}
