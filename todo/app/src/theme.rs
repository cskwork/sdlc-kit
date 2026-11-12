//! Look and feel: a built-in Hangul font, paper tones in light and dark like a book's page, cards, and tray icons.
use eframe::egui::{self, Color32, CornerRadius, FontData, FontDefinitions, FontFamily, FontId, Margin, Stroke, TextStyle, Theme};
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone, Copy)]
pub struct Palette {
    pub bg: Color32,
    pub card: Color32,
    pub card_hover: Color32,
    pub stroke: Color32,
    pub text: Color32,
    pub muted: Color32,
    pub accent: Color32,
    pub on_accent: Color32,
}

pub fn palette(dark: bool) -> Palette {
    if dark {
        Palette { bg: hex(0x161412), card: hex(0x1f1c19), card_hover: hex(0x27231f), stroke: hex(0x36312b),
            text: hex(0xebe5da), muted: hex(0xa39a8d), accent: hex(0x9a99ff), on_accent: hex(0x12100e) }
    } else {
        Palette { bg: hex(0xf1ede4), card: hex(0xfcfaf5), card_hover: hex(0xf6f2e9), stroke: hex(0xe3dccd),
            text: hex(0x26221e), muted: hex(0x756c61), accent: hex(0x5553d4), on_accent: hex(0xffffff) }
    }
}

/// Tint for an actor: (text, background).
pub fn tone(actor: &str, dark: bool) -> (Color32, Color32) {
    let (fg, bg_light, bg_dark) = match actor {
        "you" => (0xd97706, 0xfef3c7, 0x3a2a0c),
        "agent" => (0x2f6fed, 0xdde8ff, 0x16233f),
        // An agent working on it right now, apart from an agent's turn nobody holds.
        "working" => (0x0a7a52, 0xe3f6ee, 0x123227),
        "blocked" => (0xdc2626, 0xfee2e2, 0x3d1616),
        _ => (0x6b7280, 0xececf0, 0x26262b),
    };
    let fg = if dark { lighten(hex(fg)) } else { hex(fg) };
    (fg, hex(if dark { bg_dark } else { bg_light }))
}

fn hex(value: u32) -> Color32 { Color32::from_rgb((value >> 16) as u8, (value >> 8) as u8, value as u8) }
fn lighten(c: Color32) -> Color32 {
    let up = |v: u8| v.saturating_add(((255 - v as u16) * 2 / 5) as u8);
    Color32::from_rgb(up(c.r()), up(c.g()), up(c.b()))
}

fn system_fonts() -> Vec<(&'static str, Vec<u8>)> {
    let candidates: &[&str] = if cfg!(target_os = "macos") {
        &["/System/Library/Fonts/AppleSDGothicNeo.ttc"]
    } else if cfg!(windows) {
        &["C:\\Windows\\Fonts\\segoeui.ttf", "C:\\Windows\\Fonts\\malgun.ttf"]
    } else {
        &["/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
          "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc"]
    };
    candidates.iter().filter_map(|path| std::fs::read(path).ok().map(|bytes| (*path, bytes))).collect()
}

/// The default text font, built in so every machine reads the same: Pretendard Regular (SIL OFL 1.1,
/// licence beside the file). System fonts follow it for glyphs it lacks.
const BUILT_IN: &[u8] = include_bytes!("../fonts/Pretendard-Regular.otf");

/// Other readable fonts with Hangul the human can pick when installed, by file name without spaces, dashes or case.
const KNOWN_FONTS: [(&str, &str); 11] = [
    ("applesdgothicneo", "Apple SD Gothic Neo"), ("malgun", "Malgun Gothic"), ("notosanscjk", "Noto Sans CJK"),
    ("notosanskr", "Noto Sans KR"), ("nanumgothic", "NanumGothic"), ("nanumsquare", "NanumSquare"),
    ("spoqahansansneo", "Spoqa Han Sans Neo"), ("suit", "SUIT"),
    ("applegothic", "AppleGothic"), ("applemyungjo", "AppleMyungjo"), ("nanummyeongjo", "NanumMyeongjo"),
];

/// The known fonts found on this machine, as (name, file): the regular face of each.
pub fn fonts() -> Vec<(String, String)> {
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).map(PathBuf::from).unwrap_or_default();
    let dirs: Vec<PathBuf> = if cfg!(target_os = "macos") {
        vec!["/System/Library/Fonts".into(), "/System/Library/Fonts/Supplemental".into(), "/Library/Fonts".into(), home.join("Library/Fonts")]
    } else if cfg!(windows) {
        vec!["C:\\Windows\\Fonts".into(), home.join("AppData\\Local\\Microsoft\\Windows\\Fonts")]
    } else {
        vec!["/usr/share/fonts/opentype/noto".into(), "/usr/share/fonts/noto-cjk".into(), "/usr/share/fonts/google-noto-cjk".into(),
             "/usr/share/fonts/truetype/nanum".into(), home.join(".local/share/fonts"), home.join(".fonts")]
    };
    let mut files: Vec<PathBuf> = dirs.iter().filter_map(|dir| std::fs::read_dir(dir).ok()).flatten().filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.extension().and_then(|e| e.to_str()).is_some_and(|e| ["ttf", "otf", "ttc"].contains(&e.to_lowercase().as_str())))
        .collect();
    files.sort();
    let stem = |path: &PathBuf| path.file_stem().map(|s| s.to_string_lossy().to_lowercase().replace([' ', '-', '_'], "")).unwrap_or_default();
    KNOWN_FONTS.iter().filter_map(|(key, name)| {
        let file = files.iter().find(|path| { let stem = stem(path); stem == *key || stem == format!("{key}regular") || stem == format!("{key}variable") })?;
        Some((name.to_string(), file.to_string_lossy().to_string()))
    }).collect()
}

/// Sets fonts and the look. `font` is a file from `fonts()` that leads the text, or empty for the built-in one.
pub fn install(ctx: &egui::Context, font: &str) {
    let mut fonts = FontDefinitions::default();
    // epaint panics on font data it cannot parse, and this path comes from the settings file: a truncated
    // or replaced file would crash every launch, so it is checked first and skipped for the built-in one.
    let chosen = (!font.is_empty()).then(|| std::fs::read(font).ok().map(|bytes| (font, bytes))).flatten()
        .filter(|(_, bytes)| ttf_parser::Face::parse(bytes, 0).is_ok());
    for (index, (path, bytes)) in chosen.into_iter().chain([("Pretendard", BUILT_IN.to_vec())]).chain(system_fonts()).enumerate() {
        fonts.font_data.insert(path.to_string(), Arc::new(FontData::from_owned(bytes)));
        for family in [FontFamily::Proportional, FontFamily::Monospace] {
            let list = fonts.families.entry(family.clone()).or_default();
            // System fonts lead the proportional family; monospace keeps its own glyphs and falls back for Hangul.
            if family == FontFamily::Proportional { list.insert(index, path.to_string()); } else { list.push(path.to_string()); }
        }
    }
    ctx.set_fonts(fonts);
    for theme in [Theme::Light, Theme::Dark] {
        let p = palette(theme == Theme::Dark);
        ctx.style_mut_of(theme, |style| {
            style.text_styles = [
                (TextStyle::Heading, FontId::proportional(22.0)),
                (TextStyle::Body, FontId::proportional(14.0)),
                (TextStyle::Button, FontId::proportional(13.5)),
                (TextStyle::Small, FontId::proportional(11.5)),
                (TextStyle::Monospace, FontId::monospace(12.5)),
            ].into();
            style.spacing.item_spacing = egui::vec2(8.0, 8.0);
            style.spacing.button_padding = egui::vec2(12.0, 6.0);
            style.spacing.interact_size.y = 30.0;
            let v = &mut style.visuals;
            v.panel_fill = p.bg;
            v.window_fill = p.card;
            v.extreme_bg_color = p.card;
            v.faint_bg_color = p.card_hover;
            v.override_text_color = Some(p.text);
            v.hyperlink_color = p.accent;
            v.selection.bg_fill = p.accent.gamma_multiply(0.35);
            v.selection.stroke = Stroke::new(1.0, p.accent);
            v.window_corner_radius = CornerRadius::same(14);
            v.menu_corner_radius = CornerRadius::same(10);
            for w in [&mut v.widgets.inactive, &mut v.widgets.hovered, &mut v.widgets.active, &mut v.widgets.noninteractive, &mut v.widgets.open] {
                w.corner_radius = CornerRadius::same(8);
            }
            v.widgets.noninteractive.bg_stroke = Stroke::new(1.0, p.stroke);
            v.widgets.inactive.weak_bg_fill = p.card_hover;
            v.widgets.inactive.bg_stroke = Stroke::new(1.0, p.stroke);
            v.widgets.hovered.weak_bg_fill = p.card_hover;
            v.widgets.hovered.bg_stroke = Stroke::new(1.0, p.accent.gamma_multiply(0.6));
            v.widgets.active.bg_stroke = Stroke::new(1.0, p.accent);
        });
    }
}

pub fn card(p: &Palette) -> egui::Frame {
    egui::Frame::new()
        .fill(p.card)
        .stroke(Stroke::new(1.0, p.stroke))
        .corner_radius(CornerRadius::same(12))
        .inner_margin(Margin::symmetric(14, 12))
}

/// A decision's page: paper with wide margins, lifted a little off the desk.
pub fn page(p: &Palette) -> egui::Frame {
    card(p).corner_radius(CornerRadius::same(8)).inner_margin(Margin::symmetric(26, 22))
        .shadow(egui::Shadow { offset: [0, 3], blur: 14, spread: 0, color: Color32::from_black_alpha(22) })
}

/// A list row: the card look, tighter, for one line that opens on demand.
pub fn row(p: &Palette) -> egui::Frame { card(p).corner_radius(CornerRadius::same(10)).inner_margin(Margin::symmetric(12, 8)) }

/// A 32×32 tray glyph: a rounded check box, with a dot when something needs the human.
pub fn tray_icon(alert: bool, template: bool) -> tray_icon::Icon {
    let size = 32usize;
    let mut rgba = vec![0u8; size * size * 4];
    let ink = if template { [0, 0, 0] } else { [94, 92, 230] };
    let mut put = |x: usize, y: usize, c: [u8; 3], a: u8| {
        let i = (y * size + x) * 4;
        rgba[i..i + 4].copy_from_slice(&[c[0], c[1], c[2], a]);
    };
    for y in 0..size {
        for x in 0..size {
            let (fx, fy) = (x as f32 + 0.5, y as f32 + 0.5);
            // Rounded square outline from 5 to 27 with radius 6, 2.5px stroke.
            let (cx, cy) = (fx.clamp(11.0, 21.0), fy.clamp(11.0, 21.0));
            let d = ((fx - cx).powi(2) + (fy - cy).powi(2)).sqrt();
            if (d - 6.0).abs() <= 1.4 { put(x, y, ink, 255); }
            // Check mark: two strokes.
            let on_segment = |ax: f32, ay: f32, bx: f32, by: f32| {
                let (dx, dy) = (bx - ax, by - ay);
                let t = (((fx - ax) * dx + (fy - ay) * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
                ((fx - ax - t * dx).powi(2) + (fy - ay - t * dy).powi(2)).sqrt() <= 1.4
            };
            if on_segment(11.0, 16.5, 14.5, 20.0) || on_segment(14.5, 20.0, 21.0, 12.0) { put(x, y, ink, 255); }
            if alert {
                let d = ((fx - 26.0).powi(2) + (fy - 6.0).powi(2)).sqrt();
                if d <= 5.5 { put(x, y, if template { [0, 0, 0] } else { [239, 68, 68] }, 255); }
            }
        }
    }
    tray_icon::Icon::from_rgba(rgba, size as u32, size as u32).expect("valid tray icon")
}
