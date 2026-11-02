//! Look and feel: system fonts with Hangul, a quiet light/dark palette, rounded cards, and tray icons.
use eframe::egui::{self, Color32, CornerRadius, FontData, FontDefinitions, FontFamily, FontId, Margin, Stroke, TextStyle, Theme};
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
        Palette { bg: hex(0x111113), card: hex(0x1b1b1f), card_hover: hex(0x222227), stroke: hex(0x2c2c33),
            text: hex(0xededf0), muted: hex(0x9a9aa6), accent: hex(0x8b8aff), on_accent: hex(0x0f0f14) }
    } else {
        Palette { bg: hex(0xf6f6f8), card: hex(0xffffff), card_hover: hex(0xfafafc), stroke: hex(0xe5e5ea),
            text: hex(0x1c1c1f), muted: hex(0x6b6b76), accent: hex(0x5e5ce6), on_accent: hex(0xffffff) }
    }
}

/// Tint for an actor: (text, background).
pub fn tone(actor: &str, dark: bool) -> (Color32, Color32) {
    let (fg, bg_light, bg_dark) = match actor {
        "you" => (0xd97706, 0xfef3c7, 0x3a2a0c),
        "agent" => (0x2f6fed, 0xdde8ff, 0x16233f),
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

pub fn install(ctx: &egui::Context) {
    let mut fonts = FontDefinitions::default();
    for (index, (path, bytes)) in system_fonts().into_iter().enumerate() {
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
