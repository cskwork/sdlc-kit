//! The menu-bar (tray) icon: a glyph, the count of items that need the human, and the menu.
use crate::i18n::{t, Lang};
use std::sync::atomic::{AtomicUsize, Ordering};
use tauri::image::Image;
use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::AppHandle;

const ID: &str = "main";
/// The macOS menu bar colours the icon itself; elsewhere it keeps its own colours.
const TEMPLATE: bool = cfg!(target_os = "macos");

/// What the person picked on the tray.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Pick { Board, List, Quit }

pub fn build(app: &AppHandle, lang: Lang, pick: impl Fn(&AppHandle, Pick) + Clone + Send + Sync + 'static) -> tauri::Result<()> {
    let item = |id: &str, key: &str| MenuItemBuilder::with_id(id, t(lang, key)).build(app);
    let menu = MenuBuilder::new(app).items(&[&item("board", "tray.board")?, &item("list", "tray.list")?]).separator()
        .item(&item("quit", "tray.quit")?).build()?;
    let click = pick.clone();
    TrayIconBuilder::with_id(ID)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .icon(icon(false)).icon_as_template(TEMPLATE)
        .tooltip(t(lang, "title"))
        .on_menu_event(move |app, event| match event.id().as_ref() {
            "board" => pick(app, Pick::Board),
            "list" => pick(app, Pick::List),
            "quit" => pick(app, Pick::Quit),
            _ => {}
        })
        // A left click opens the board; the right button keeps the menu.
        .on_tray_icon_event(move |tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                click(tray.app_handle(), Pick::Board);
            }
        })
        .build(app)?;
    Ok(())
}

/// Sets the badge and tooltip to `count`.
pub fn show_count(app: &AppHandle, count: usize, lang: Lang) {
    static SHOWN: AtomicUsize = AtomicUsize::new(usize::MAX);
    // The language decides the tooltip too; both fit one number.
    let state = count * 2 + usize::from(lang == Lang::Ko);
    if SHOWN.swap(state, Ordering::SeqCst) == state { return; }
    let Some(tray) = app.tray_by_id(ID) else { return };
    let _ = tray.set_icon_with_as_template(Some(icon(count > 0)), TEMPLATE);
    #[cfg(target_os = "macos")]
    let _ = tray.set_title(Some(if count > 0 { count.to_string() } else { String::new() }));
    let _ = tray.set_tooltip(Some(format!("{} · {} {count}", t(lang, "title"), t(lang, "tab.focus"))));
}

/// A 32×32 tray glyph: a rounded check box, with a dot when something needs the human.
fn icon(alert: bool) -> Image<'static> {
    let size = 32usize;
    let mut rgba = vec![0u8; size * size * 4];
    let ink = if TEMPLATE { [0, 0, 0] } else { [94, 92, 230] };
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
                if d <= 5.5 { put(x, y, if TEMPLATE { [0, 0, 0] } else { [239, 68, 68] }, 255); }
            }
        }
    }
    Image::new_owned(rgba, size as u32, size as u32)
}
