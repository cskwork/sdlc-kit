//! sdlc-todo: a small tray app for the sdlc-kit to-do. It never edits todo.md itself; every
//! change goes through the same web API as the browser page, so the TUI, page and app agree.
#![cfg_attr(windows, windows_subsystem = "windows")]
mod client;
mod i18n;
mod prefs;
mod theme;

use client::{Artifact, Item, Launcher, Model, Session};
use eframe::egui::{self, Align, Color32, CornerRadius, Layout, Margin, RichText, Sense, Stroke, ViewportCommand};
use i18n::{t, Lang};
use prefs::Prefs;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::process::Child;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{TrayIcon, TrayIconBuilder, TrayIconEvent};

#[derive(Clone, PartialEq)]
enum Conn { Connecting, Live, Offline(String) }

struct Shared {
    model: Option<Model>,
    conn: Conn,
    session: Option<Session>,
    child: Option<Child>,
    toast: Option<(String, bool, Instant)>,
    artifacts: HashMap<String, Result<Artifact, String>>,
    busy: HashSet<String>,
}

type State = Arc<Mutex<Shared>>;

#[derive(Clone, Copy, PartialEq)]
enum Tab { Focus, Agent, All, Done }

struct App {
    state: State,
    lang: Lang,
    tab: Tab,
    /// Rows opened on the list tabs.
    open: HashSet<String>,
    /// The decision on screen in the Needs-you tab and its place in the queue: when it leaves
    /// the queue (answered), the decision now at that place takes over.
    focus: Option<String>,
    focus_at: usize,
    /// Reply drafts by item: (text, the suggestion it started from).
    drafts: HashMap<String, (String, String)>,
    notes: HashMap<String, String>,
    /// The human's view settings and memos, saved beside the session file whenever they change.
    prefs: Prefs,
    prefs_file: PathBuf,
    prefs_dirty: bool,
    /// Fonts found on this machine, as (name, file); the settings card lists them.
    fonts: Vec<(String, String)>,
    settings: bool,
    tray: Option<TrayIcon>,
    badge: Option<usize>,
}

/// The window width, in points, from which the content opens as a two-page spread.
const SPREAD_FROM: f32 = 960.0;

/// Which side of a decision to draw: what to read, how to answer, or both on one page.
#[derive(Clone, Copy, PartialEq)]
enum Part { Both, Read, Act }

fn needs_you(item: &Item) -> bool { !item.done && matches!(item.turn.actor.as_str(), "you" | "blocked") }

/// A decision the agent recommends no answer for: a gate approval, a block, or an open question.
/// These lead the queue and are marked; the rest can be settled by taking the recommendation.
fn must_decide(item: &Item) -> bool {
    needs_you(item) && (item.turn.kind != "answer" || (item.pick.is_none() && item.suggest.trim().is_empty()))
}

fn ticket_url(item: &Item) -> Option<&str> { item.link.as_ref().map(|l| l.url.as_str()).filter(|u| !u.is_empty()) }

/// The decisions waiting for the human, shown one at a time: those without a recommendation first,
/// each with the other decisions for the same ticket. Pinned settings are not decisions.
fn decision_queue(items: &[Item]) -> Vec<&Item> {
    let mut mine: Vec<&Item> = items.iter().filter(|i| needs_you(i) && !i.pin).collect();
    mine.sort_by_key(|i| !must_decide(i));
    let mut out: Vec<&Item> = Vec::new();
    for item in &mine {
        if out.iter().any(|o| o.id == item.id) { continue; }
        let mut group: Vec<&Item> = match ticket_url(item) {
            Some(url) => mine.iter().copied().filter(|other| ticket_url(other) == Some(url)).collect(),
            None => vec![*item],
        };
        // Within a ticket the item that offers choices is the decision; one beside it often only points there.
        group.sort_by_key(|i| i.choices.is_empty());
        out.extend(group);
    }
    out
}

/// Where the focus lands: on the same decision while it waits, else on whatever now sits at its place.
fn settle(focus: Option<&str>, at: usize, queue: &[&str]) -> Option<usize> {
    if queue.is_empty() { return None; }
    Some(focus.and_then(|id| queue.iter().position(|q| *q == id)).unwrap_or(at.min(queue.len() - 1)))
}

fn status_label(lang: Lang, item: &Item) -> &'static str {
    match item.turn.kind.as_str() {
        "approve-intent" => t(lang, "status.approve-intent"),
        "approve-plan" => t(lang, "status.approve-plan"),
        "answer" => t(lang, "status.answer"),
        "agent" => t(lang, "status.agent"),
        "handoff" => t(lang, "status.handoff"),
        "blocked" => t(lang, "status.blocked"),
        "others" => t(lang, "status.others"),
        "done" => t(lang, "status.done"),
        _ => t(lang, "status.new"),
    }
}

fn open_url(url: &str) {
    let (program, args): (&str, Vec<&str>) = if cfg!(target_os = "macos") { ("open", vec![url]) }
        else if cfg!(windows) { ("rundll32.exe", vec!["url.dll,FileProtocolHandler", url]) }
        else { ("xdg-open", vec![url]) };
    let _ = std::process::Command::new(program).args(args).spawn();
}

/// Opens Terminal with `command` typed at the prompt but not run, so the human reads it and presses Enter.
/// A throwaway ZDOTDIR loads the human's ~/.zshrc, then `print -z` puts the command in the line editor; nothing is
/// typed into the terminal, so nothing can run early. Returns false where that is not possible (not macOS, no zsh).
fn open_terminal(command: &str) -> bool {
    if !cfg!(target_os = "macos") || !std::path::Path::new("/bin/zsh").exists() { return false; }
    let quote = |text: &str| format!("'{}'", text.replace('\'', "'\\''"));
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or_default();
    let dir = std::env::temp_dir().join(format!("sdlc-run-{}-{stamp}", std::process::id()));
    let dir_text = dir.to_string_lossy().to_string();
    let rc = format!("ZDOTDIR=$HOME\n[[ -f $HOME/.zshrc ]] && source $HOME/.zshrc\ncommand rm -rf -- {}\nprint -rz -- {}\n", quote(&dir_text), quote(command));
    // Terminal's session restore would write under the throwaway directory; this shell needs none.
    let launcher = format!("#!/bin/zsh\nSHELL_SESSIONS_DISABLE=1 ZDOTDIR={} exec /bin/zsh -i\n", quote(&dir_text));
    let script = dir.join("run.command");
    let written = std::fs::create_dir_all(&dir).is_ok() && std::fs::write(dir.join(".zshrc"), rc).is_ok() && std::fs::write(&script, launcher).is_ok();
    #[cfg(unix)]
    let written = written && { use std::os::unix::fs::PermissionsExt; std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).is_ok() };
    written && std::process::Command::new("open").args(["-a", "Terminal"]).arg(&script).spawn().is_ok()
}

fn quit(state: &State) -> ! {
    if let Ok(mut shared) = state.lock() {
        if let Some(mut child) = shared.child.take() { let _ = child.kill(); }
    }
    std::process::exit(0)
}

/// Finds or starts the server, then follows its events; reconnects whenever the stream drops.
fn connect(state: State, ctx: egui::Context, launcher: Launcher, lang: Lang) {
    std::thread::spawn(move || {
        let mut known: Option<HashSet<String>> = None;
        loop {
            let session = match client::live(&launcher.session_file) {
                Some(session) => session,
                None => {
                    state.lock().unwrap().conn = Conn::Connecting;
                    ctx.request_repaint();
                    match launcher.serve() {
                        Ok((child, session)) => {
                            let mut shared = state.lock().unwrap();
                            if let Some(mut old) = shared.child.replace(child) { let _ = old.kill(); }
                            session
                        }
                        Err(error) => {
                            state.lock().unwrap().conn = Conn::Offline(format!("{}{error}", t(lang, "server.failed")));
                            ctx.request_repaint();
                            std::thread::sleep(Duration::from_secs(5));
                            continue;
                        }
                    }
                }
            };
            state.lock().unwrap().session = Some(session.clone());
            let result = client::follow(&session, |model| {
                let current: HashSet<String> = model.items.iter().filter(|i| needs_you(i)).map(|i| i.id.clone()).collect();
                if let Some(previous) = &known {
                    for item in model.items.iter().filter(|i| current.contains(&i.id) && !previous.contains(&i.id)) {
                        let _ = notify_rust::Notification::new()
                            .summary(t(lang, "notify.title"))
                            .body(&format!("{} · {}", status_label(lang, item), item.title))
                            .show();
                    }
                }
                known = Some(current);
                let mut shared = state.lock().unwrap();
                shared.model = Some(model);
                shared.conn = Conn::Live;
                drop(shared);
                ctx.request_repaint();
            });
            if let Err(error) = result {
                state.lock().unwrap().conn = Conn::Offline(error);
                ctx.request_repaint();
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    });
}

impl App {
    fn new(cc: &eframe::CreationContext, launcher: Launcher, lang: Lang) -> App {
        let prefs_file = launcher.session_file.with_file_name("todo-app.json");
        let (mut prefs, prefs_error) = Prefs::load(&prefs_file);
        let fonts = theme::fonts();
        // Only a font found on this machine leads; a path that is gone falls back to the built-in one.
        if !fonts.iter().any(|(_, file)| *file == prefs.font) { prefs.font.clear(); }
        theme::install(&cc.egui_ctx, &prefs.font);
        cc.egui_ctx.set_zoom_factor(prefs.zoom);
        let state: State = Arc::new(Mutex::new(Shared {
            model: None, conn: Conn::Connecting, session: None, child: None,
            toast: prefs_error.map(|error| (error, true, Instant::now())),
            artifacts: HashMap::new(), busy: HashSet::new(),
        }));
        let tray = build_tray(lang).ok();
        let ctx = cc.egui_ctx.clone();
        let (menu_state, menu_ctx) = (state.clone(), ctx.clone());
        MenuEvent::set_event_handler(Some(move |event: MenuEvent| match event.id.0.as_str() {
            "open" => { menu_ctx.send_viewport_cmd(ViewportCommand::Visible(true)); menu_ctx.send_viewport_cmd(ViewportCommand::Focus); }
            "quit" => quit(&menu_state),
            _ => {}
        }));
        let click_ctx = ctx.clone();
        TrayIconEvent::set_event_handler(Some(move |event: TrayIconEvent| {
            if let TrayIconEvent::DoubleClick { .. } = event {
                click_ctx.send_viewport_cmd(ViewportCommand::Visible(true));
                click_ctx.send_viewport_cmd(ViewportCommand::Focus);
            }
        }));
        connect(state.clone(), ctx, launcher, lang);
        App { state, lang, tab: Tab::Focus, open: HashSet::new(), focus: None, focus_at: 0, drafts: HashMap::new(), notes: HashMap::new(),
            prefs, prefs_file, prefs_dirty: false, fonts, settings: false, tray, badge: None }
    }

    /// Runs one request off the UI thread; the event stream brings the new list back.
    fn act(&self, ctx: &egui::Context, id: &str, job: impl FnOnce(&Session) -> Result<String, String> + Send + 'static) {
        let Some(session) = self.state.lock().unwrap().session.clone() else { return };
        let (state, ctx, id) = (self.state.clone(), ctx.clone(), id.to_string());
        state.lock().unwrap().busy.insert(id.clone());
        std::thread::spawn(move || {
            let result = job(&session);
            let mut shared = state.lock().unwrap();
            shared.busy.remove(&id);
            shared.toast = Some(match result { Ok(text) => (text, false, Instant::now()), Err(text) => (text, true, Instant::now()) });
            drop(shared);
            ctx.request_repaint();
        });
    }

    fn update_tray(&mut self, count: usize) {
        if self.badge == Some(count) { return; }
        self.badge = Some(count);
        if let Some(tray) = &self.tray {
            let _ = tray.set_icon(Some(theme::tray_icon(count > 0, cfg!(target_os = "macos"))));
            if cfg!(target_os = "macos") { tray.set_icon_as_template(true); }
            #[cfg(target_os = "macos")]
            tray.set_title(if count > 0 { Some(count.to_string()) } else { None });
            let _ = tray.set_tooltip(Some(format!("{} · {} {count}", t(self.lang, "title"), t(self.lang, "tab.focus"))));
        }
    }
}

fn build_tray(lang: Lang) -> Result<TrayIcon, String> {
    let menu = Menu::new();
    let items = [
        MenuItem::with_id("open", t(lang, "tray.open"), true, None),
    ];
    for item in &items { menu.append(item).map_err(|e| e.to_string())?; }
    menu.append(&PredefinedMenuItem::separator()).map_err(|e| e.to_string())?;
    menu.append(&MenuItem::with_id("quit", t(lang, "tray.quit"), true, None)).map_err(|e| e.to_string())?;
    TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_icon(theme::tray_icon(false, cfg!(target_os = "macos")))
        .with_icon_as_template(cfg!(target_os = "macos"))
        .with_tooltip(t(lang, "title"))
        .build()
        .map_err(|e| e.to_string())
}

fn pill(ui: &mut egui::Ui, text: &str, actor: &str, dark: bool) {
    let (fg, bg) = theme::tone(actor, dark);
    egui::Frame::new().fill(bg).corner_radius(CornerRadius::same(255)).inner_margin(Margin::symmetric(9, 3))
        .show(ui, |ui| ui.label(RichText::new(text).color(fg).size(11.5).strong()));
}

fn primary(ui: &mut egui::Ui, p: &theme::Palette, text: &str, enabled: bool) -> egui::Response {
    ui.add_enabled(enabled, egui::Button::new(RichText::new(text).color(p.on_accent).strong())
        .fill(p.accent).stroke(Stroke::NONE).corner_radius(CornerRadius::same(8)).min_size(egui::vec2(0.0, 30.0)))
}

fn markdown(ui: &mut egui::Ui, p: &theme::Palette, text: &str) {
    let mut code = false;
    for line in text.lines() {
        if line.trim_start().starts_with("```") { code = !code; continue; }
        if code { ui.label(RichText::new(line).monospace().color(p.muted)); continue; }
        let trimmed = line.trim();
        if trimmed.is_empty() { ui.add_space(2.0); }
        else if let Some(h) = trimmed.strip_prefix("# ") { ui.label(RichText::new(h).size(17.0).strong()); }
        else if let Some(h) = trimmed.strip_prefix("## ") { ui.add_space(4.0); ui.label(RichText::new(h).size(15.0).strong()); }
        else if let Some(h) = trimmed.strip_prefix("### ") { ui.label(RichText::new(h).strong()); }
        else if let Some(b) = trimmed.strip_prefix("- ").or_else(|| trimmed.strip_prefix("* ")) {
            ui.horizontal_top(|ui| { ui.label(RichText::new("•").color(p.accent)); ui.add(egui::Label::new(b.replace("**", "").replace('`', "")).wrap()); });
        } else { ui.label(trimmed.replace("**", "").replace('`', "")); }
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if ctx.input(|i| i.viewport().close_requested()) {
            ctx.send_viewport_cmd(ViewportCommand::CancelClose);
            ctx.send_viewport_cmd(ViewportCommand::Visible(false));
        }
        let (model, conn, toast, busy, artifacts) = {
            let mut shared = self.state.lock().unwrap();
            if shared.toast.as_ref().is_some_and(|(_, _, at)| at.elapsed() > Duration::from_secs(5)) { shared.toast = None; }
            (shared.model.clone().unwrap_or_default(), shared.conn.clone(), shared.toast.clone(), shared.busy.clone(), shared.artifacts.clone())
        };
        if !model.lang.is_empty() { self.lang = Lang::parse(&model.lang); }
        let lang = self.lang;
        let attention = model.items.iter().filter(|i| needs_you(i)).count();
        self.update_tray(attention);
        if toast.is_some() { ctx.request_repaint_after(Duration::from_millis(500)); }
        // The keyboard zoom (Cmd/Ctrl with + and -) is kept like the settings card's.
        let zoom = ctx.zoom_factor().clamp(prefs::ZOOM.0, prefs::ZOOM.1);
        // The keys have no limit of their own; hold the real zoom to the range the saved one keeps.
        if zoom != ctx.zoom_factor() { ctx.set_zoom_factor(zoom); }
        if (zoom - self.prefs.zoom).abs() > 0.001 { self.prefs.zoom = zoom; self.prefs_dirty = true; }

        let dark = ctx.style().visuals.dark_mode;
        let p = theme::palette(dark);
        egui::CentralPanel::default()
            .frame(egui::Frame::new().fill(p.bg).inner_margin(Margin::symmetric(18, 16)))
            .show(ctx, |ui| {
                // Lines keep a readable length: a wide window opens like a book, two pages side by side, and a
                // narrow one keeps a single page.
                let full = ui.max_rect();
                let spread = full.width() >= SPREAD_FROM;
                let column = egui::Rect::from_center_size(full.center(), egui::vec2(full.width().min(if spread { 1240.0 } else { 760.0 }), full.height()));
                ui.allocate_new_ui(egui::UiBuilder::new().max_rect(column), |ui| {
                    ui.horizontal(|ui| {
                        ui.heading(RichText::new(t(lang, "title")).strong());
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            // Live is the normal state and gets only a dot; trouble gets words.
                            let (color, text) = match &conn {
                                Conn::Live => (Color32::from_rgb(34, 197, 94), ""),
                                Conn::Connecting => (Color32::from_rgb(245, 158, 11), t(lang, "connecting")),
                                Conn::Offline(_) => (Color32::from_rgb(239, 68, 68), t(lang, "offline")),
                            };
                            if !text.is_empty() { ui.label(RichText::new(text).color(p.muted).size(12.0)); }
                            let (rect, dot) = ui.allocate_exact_size(egui::vec2(8.0, 8.0), Sense::hover());
                            ui.painter().circle_filled(rect.center(), 4.0, color);
                            if text.is_empty() { dot.on_hover_text(t(lang, "live")); }
                            let view = egui::Button::new(RichText::new(t(lang, "view")).color(p.muted).size(13.0)).frame(self.settings).corner_radius(CornerRadius::same(8));
                            if ui.add(view).on_hover_text(t(lang, "view.help")).clicked() { self.settings = !self.settings; }
                        });
                    });
                    if self.settings { self.view_settings(ui, ctx, &p); }
                    if let Conn::Offline(reason) = &conn {
                        ui.label(RichText::new(reason).color(theme::tone("blocked", dark).0).size(12.0));
                    }
                    ui.add_space(6.0);
                    let queue = decision_queue(&model.items);
                    // Items waiting on someone else are in progress, not yours.
                    let in_progress = |i: &Item| !i.done && !i.pin && matches!(i.turn.actor.as_str(), "agent" | "others");
                    let counts = [Some(queue.len()), Some(model.items.iter().filter(|i| in_progress(i)).count()), None, None];
                    egui::Frame::new().fill(p.card).stroke(Stroke::new(1.0, p.stroke)).corner_radius(CornerRadius::same(10))
                        .inner_margin(Margin::same(3)).show(ui, |ui| {
                            ui.horizontal(|ui| {
                                ui.spacing_mut().item_spacing.x = 2.0;
                                for ((tab, key), count) in [(Tab::Focus, "tab.focus"), (Tab::Agent, "tab.agent"), (Tab::All, "tab.all"), (Tab::Done, "tab.done")].into_iter().zip(counts) {
                                    let selected = self.tab == tab;
                                    let label = match count { Some(n) if n > 0 => format!("{} {n}", t(lang, key)), _ => t(lang, key).to_string() };
                                    let text = RichText::new(label).color(if selected { p.on_accent } else { p.muted }).strong();
                                    let button = egui::Button::new(text).fill(if selected { p.accent } else { Color32::TRANSPARENT })
                                        .stroke(Stroke::NONE).corner_radius(CornerRadius::same(8));
                                    if ui.add(button).clicked() { self.tab = tab; }
                                }
                            });
                        });
                    ui.add_space(10.0);

                    // Pinned items (settings) sit above every open tab, outside the tab's own list and counts.
                    let pinned: Vec<&Item> = if self.tab == Tab::Done { Vec::new() } else { model.items.iter().filter(|i| i.pin && !i.done).collect() };
                    let listed: Vec<&Item> = model.items.iter().filter(|i| !(i.pin && !i.done)).filter(|i| match self.tab {
                        Tab::Focus => false,
                        Tab::Agent => in_progress(i),
                        Tab::All => !i.done,
                        Tab::Done => i.done,
                    }).collect();
                    let toast_height = if toast.is_some() { 44.0 } else { 0.0 };
                    // The decision on screen: the same one while it waits, else whatever now sits at its place.
                    // Arrow keys turn the page unless a field is being typed in.
                    let on_focus = self.tab == Tab::Focus;
                    let ids: Vec<&str> = queue.iter().map(|i| i.id.as_str()).collect();
                    let mut at = if on_focus { settle(self.focus.as_deref(), self.focus_at, &ids) } else { None };
                    if let Some(now) = at {
                        let step = if ctx.memory(|m| m.focused().is_some()) { 0 } else {
                            ctx.input(|i| i.key_pressed(egui::Key::ArrowRight) as isize - i.key_pressed(egui::Key::ArrowLeft) as isize)
                        };
                        at = Some(now.saturating_add_signed(step).min(queue.len() - 1));
                    }
                    let foot_height = if at.is_some() && queue.len() > 1 { 42.0 } else { 0.0 };
                    // Each decision opens at its top: the scroll offset is kept per decision, not carried to the next.
                    let scroll_id = at.map(|now| queue[now].id.clone()).unwrap_or_default();
                    egui::ScrollArea::vertical().id_salt(("main", scroll_id)).max_height(ui.available_height() - toast_height - foot_height).auto_shrink([false, false]).show(ui, |ui| {
                        ui.add_space(1.0);
                        for item in &pinned {
                            self.pinned(ui, ctx, &p, item, busy.contains(&item.id));
                            ui.add_space(8.0);
                        }
                        if on_focus {
                            // One decision at a time; answering it brings the next one up.
                            match at {
                                Some(now) => at = Some(self.decision(ui, ctx, &p, dark, spread, &queue, now, &busy, &artifacts)),
                                None if conn == Conn::Live => {
                                    ui.add_space(40.0);
                                    ui.vertical_centered(|ui| ui.label(RichText::new(t(lang, "empty.focus")).color(p.muted)));
                                }
                                None => {}
                            }
                            return;
                        }
                        if listed.is_empty() && conn == Conn::Live {
                            ui.add_space(40.0);
                            ui.vertical_centered(|ui| ui.label(RichText::new(t(lang, "empty")).color(p.muted)));
                        }
                        // On a wide window the list runs down two columns.
                        let two = spread && listed.len() > 1;
                        let per_column = if two { listed.len().div_ceil(2) } else { listed.len().max(1) };
                        let mut clicked: Option<&Item> = None;
                        ui.columns(if two { 2 } else { 1 }, |columns| {
                            for (column, items) in columns.iter_mut().zip(listed.chunks(per_column)) {
                                for item in items {
                                    if self.row(column, ctx, &p, dark, item, busy.contains(&item.id), artifacts.get(&artifact_key(item))) { clicked = Some(*item); }
                                    column.add_space(6.0);
                                }
                            }
                        });
                        if let Some(item) = clicked {
                            // A decision is made in one place: its line leads to the Needs-you tab.
                            if needs_you(item) { (self.tab, self.focus) = (Tab::Focus, Some(item.id.clone())); }
                            else if !self.open.remove(&item.id) { self.open.insert(item.id.clone()); }
                        }
                    });
                    // The page number sits at the foot like a book's, with the arrows that turn the page.
                    if let Some(now) = at.filter(|_| queue.len() > 1) {
                        ui.add_space(6.0);
                        ui.horizontal(|ui| {
                            ui.add_space(((ui.available_width() - 150.0) / 2.0).max(0.0));
                            let arrow = |ui: &mut egui::Ui, glyph: &str, enabled: bool| ui.add_enabled(enabled,
                                egui::Button::new(RichText::new(glyph).size(15.0).strong()).corner_radius(CornerRadius::same(8)).min_size(egui::vec2(30.0, 28.0))).clicked();
                            if arrow(ui, "‹", now > 0) { at = Some(now - 1); }
                            ui.add_sized([70.0, 28.0], egui::Label::new(RichText::new(format!("{} / {}", now + 1, queue.len())).color(p.muted).size(13.0).strong()));
                            if arrow(ui, "›", now + 1 < queue.len()) { at = Some(now + 1); }
                        });
                    }
                    if on_focus { (self.focus, self.focus_at) = (at.map(|now| queue[now].id.clone()), at.unwrap_or(0)); }
                    if let Some((text, error, _)) = toast {
                        let (fg, bg) = if error { theme::tone("blocked", dark) } else { (p.text, p.card) };
                        egui::Frame::new().fill(bg).stroke(Stroke::new(1.0, p.stroke)).corner_radius(CornerRadius::same(10))
                            .inner_margin(Margin::symmetric(12, 8)).show(ui, |ui| { ui.set_width(ui.available_width()); ui.label(RichText::new(text).color(fg)); });
                    }
                });
            });
        if self.prefs_dirty {
            self.prefs_dirty = false;
            // Empty memos and memos of items the list shows as done are dropped. An id the list does not have is
            // kept: ids change with title edits and items can be briefly absent, and a lost memo cannot come back.
            let done: HashSet<&str> = model.items.iter().filter(|i| i.done).map(|i| i.id.as_str()).collect();
            self.prefs.memos.retain(|id, text| !text.trim().is_empty() && !done.contains(id.as_str()));
            if let Err(error) = self.prefs.save(&self.prefs_file) {
                self.state.lock().unwrap().toast = Some((error, true, Instant::now()));
            }
        }
    }
}

impl App {
    /// Text size and font, opened from the header: the human's own, kept across runs.
    fn view_settings(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, p: &theme::Palette) {
        let lang = self.lang;
        theme::row(p).show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal(|ui| {
                ui.label(RichText::new(t(lang, "view.size")).color(p.muted).size(12.5));
                let mut zoom = self.prefs.zoom;
                if ui.button("-").clicked() { zoom -= 0.05; }
                ui.label(RichText::new(format!("{:.0}%", self.prefs.zoom * 100.0)).strong());
                if ui.button("+").clicked() { zoom += 0.05; }
                // Whole 5% steps; the next frame sees the new factor and saves it.
                let zoom = ((zoom * 20.0).round() / 20.0).clamp(prefs::ZOOM.0, prefs::ZOOM.1);
                if zoom != self.prefs.zoom { ctx.set_zoom_factor(zoom); }
            });
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new(t(lang, "view.font")).color(p.muted).size(12.5));
                let built_in = (t(lang, "view.font.default").to_string(), String::new());
                for (name, file) in std::iter::once(built_in).chain(self.fonts.clone()) {
                    let selected = self.prefs.font == file;
                    if ui.selectable_label(selected, name).clicked() && !selected {
                        theme::install(ctx, &file);
                        self.prefs.font = file;
                        self.prefs_dirty = true;
                    }
                }
            });
        });
        ui.add_space(4.0);
    }

    /// The Needs-you tab: one decision on screen, the others folded under it. On a wide window it opens as
    /// a spread: what to read on the left page, how to answer on the right. Returns the place to show
    /// next (a click on another decision moves it).
    #[allow(clippy::too_many_arguments)]
    fn decision(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, p: &theme::Palette, dark: bool, spread: bool, queue: &[&Item], at: usize,
        busy: &HashSet<String>, artifacts: &HashMap<String, Result<Artifact, String>>) -> usize {
        let lang = self.lang;
        let item = queue[at];
        let (busy, artifact) = (busy.contains(&item.id), artifacts.get(&artifact_key(item)));
        let mut go = at;
        theme::page(p).show(ui, |ui| {
            ui.set_width(ui.available_width());
            if !spread {
                heading(ui, p, dark, lang, item);
                self.details(ui, ctx, p, item, busy, artifact, Part::Both);
                return;
            }
            // The gap between the pages; each page gets the usual spacing back, since child Uis copy the parent's.
            let spacing = ui.spacing().item_spacing.x;
            ui.spacing_mut().item_spacing.x = 44.0;
            ui.columns(2, |pages| {
                let [left, right] = pages else { return };
                left.spacing_mut().item_spacing.x = spacing;
                right.spacing_mut().item_spacing.x = spacing;
                heading(left, p, dark, lang, item);
                self.details(left, ctx, p, item, busy, artifact, Part::Read);
                right.label(RichText::new(t(lang, "page.answer")).color(p.muted).size(12.0));
                right.add_space(4.0);
                self.details(right, ctx, p, item, busy, artifact, Part::Act);
            });
            // The fold between the two pages.
            let rect = ui.min_rect();
            ui.painter().vline(rect.center().x, rect.y_range(), Stroke::new(1.0, p.stroke));
        });
        if queue.len() > 1 {
            let yours = queue.iter().enumerate().filter(|(i, other)| *i != at && must_decide(other)).count();
            let mut title = format!("{} {}", t(lang, "queue.rest"), queue.len() - 1);
            if yours > 0 { title.push_str(&format!(" · {} {yours}", t(lang, "decide.yours"))); }
            egui::CollapsingHeader::new(RichText::new(title).color(p.muted).size(12.5)).id_salt("queue").show(ui, |ui| {
                for (i, other) in queue.iter().enumerate().filter(|(i, _)| *i != at) {
                    let color = theme::tone(if must_decide(other) { &other.turn.actor } else { "" }, dark).0;
                    if line(ui, p, color, other, status_label(lang, other)) { go = i; }
                }
            });
        }
        go
    }

    /// A list tab's item: one line, opened on demand. Returns true when the line is clicked.
    #[allow(clippy::too_many_arguments)]
    fn row(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, p: &theme::Palette, dark: bool, item: &Item, busy: bool, artifact: Option<&Result<Artifact, String>>) -> bool {
        let lang = self.lang;
        let mut clicked = false;
        theme::row(p).show(ui, |ui| {
            ui.set_width(ui.available_width());
            clicked = line(ui, p, theme::tone(&item.turn.actor, dark).0, item, status_label(lang, item));
            if self.open.contains(&item.id) && !needs_you(item) {
                ui.add_space(2.0);
                ui.horizontal_wrapped(|ui| {
                    pill(ui, status_label(lang, item), &item.turn.actor, dark);
                    ui.label(RichText::new(meta_of(item)).color(p.muted).size(12.0));
                });
                self.details(ui, ctx, p, item, busy, artifact, Part::Both);
            }
        });
        clicked
    }

    /// A pinned item is one line: its title, then its choices (e.g. a setting's on/off), the current pick highlighted.
    fn pinned(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, p: &theme::Palette, item: &Item, busy: bool) {
        theme::card(p).show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new(&item.title).size(14.0).strong());
                ui.add_space(8.0);
                self.choice_buttons(ui, ctx, p, item, busy, false, &[]);
            });
        });
    }

    /// One button per offered answer; a click sends that label as an ordinary reply. Decisions put the
    /// recommended one first, each over what it does (`about`, by choice) when the document says;
    /// a pinned setting keeps its order and marks the current pick.
    #[allow(clippy::too_many_arguments)]
    fn choice_buttons(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, p: &theme::Palette, item: &Item, busy: bool, recommend: bool, about: &[String]) {
        let lang = self.lang;
        let mut order: Vec<(usize, &String)> = item.choices.iter().enumerate().collect();
        if recommend { order.sort_by_key(|(i, _)| item.pick != Some(i + 1)); }
        for (i, label) in order {
            let clicked = if item.pick == Some(i + 1) {
                let text = if recommend { format!("{label} · {}", t(lang, "choices.recommended")) } else { format!("✓ {label}") };
                primary(ui, p, &text, !busy).clicked()
            } else {
                ui.add_enabled(!busy, egui::Button::new(RichText::new(label).strong()).corner_radius(CornerRadius::same(8)).min_size(egui::vec2(0.0, 30.0))).clicked()
            };
            if clicked {
                let (id, version, text, sent) = (item.id.clone(), item.version.clone(), label.clone(), t(lang, "reply.sent"));
                self.act(ctx, &id.clone(), move |s| client::post(s, "/api/item", json!({ "id": id, "version": version, "op": "reply", "text": text })).map(|_| sent.to_string()));
            }
            if let Some(text) = about.get(i).filter(|text| !text.is_empty()) {
                ui.add(egui::Label::new(prose(text, 12.5).color(p.muted)).wrap());
                ui.add_space(2.0);
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn details(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, p: &theme::Palette, item: &Item, busy: bool, artifact: Option<&Result<Artifact, String>>, part: Part) {
        let lang = self.lang;
        let dark = ui.visuals().dark_mode;
        let action = item.sdlc.as_ref().map(|s| s.action.clone()).unwrap_or_default();
        let (label, ask) = match item.turn.actor.as_str() {
            // A gate's sdlc action is a command for agents; say what it asks in words.
            "you" if !item.turn.gate.is_empty() && item.waiting.is_empty() => (t(lang, "waits"), t(lang, if item.turn.gate == "plan" { "ask.plan" } else { "ask.intent" }).to_string()),
            "you" => (t(lang, "waits"), if item.waiting.is_empty() { action.clone() } else { item.waiting.clone() }),
            "blocked" => (t(lang, "problem"), item.error.clone().unwrap_or(action.clone())),
            "others" => (t(lang, "waits.others"), item.others.clone()),
            _ => ("", String::new()),
        };
        // The brief comes from the work document (intent.md or PLAN.md) or the item's brief file.
        let doc = if !has_document(item) { None } else {
            match artifact {
                // A spread draws this twice a frame; only the reading side fetches.
                None => { if part != Part::Act { self.load_artifact(ctx, item); } None }
                Some(Err(error)) => { if part != Part::Act { ui.label(RichText::new(error).color(theme::tone("blocked", dark).0).size(12.0)); } None }
                Some(Ok(doc)) if doc.sha.is_empty() => { if part != Part::Act { ui.label(RichText::new(t(lang, "doc.loading")).color(p.muted).size(12.0)); } None }
                Some(Ok(doc)) => Some(doc),
            }
        };
        let has_doc = doc.is_some();
        let [decide, summary, background, why, pick] = doc.map(glance).unwrap_or_default();
        // What a decision needs, in reading order: the question in its box, the situation (AS-IS), what the
        // agent does once answered (TO-BE), why it is the human's call, then the agent's pick. With a
        // document the situation and the why always show; a missing part says so. The agent's waiting line
        // joins the question only when the document asks nothing, or when the item is blocked (the line
        // is the problem).
        // The same words often come twice (the question and the waiting line, the situation and the why): show each once.
        let key = |text: &str| text.split_whitespace().collect::<String>().chars().take(40).collect::<String>();
        let mut seen: Vec<String> = Vec::new();
        let mut fresh = |lines: Vec<String>| -> Vec<String> {
            lines.into_iter().filter(|line| { let k = key(line); let new = !seen.contains(&k); if new { seen.push(k); } new }).collect()
        };
        let waiting_line = (!ask.is_empty() && (decide.is_empty() || item.turn.actor != "you")).then(|| clip(&ask, 320));
        let question = fresh(decide.into_iter().chain(waiting_line).collect());
        let none = vec![t(lang, "doc.none").to_string()];
        let (no_background, no_why) = (has_doc && background.is_empty(), has_doc && why.is_empty());
        let untagged = |lines: Vec<String>| lines.into_iter().map(untag).collect::<Vec<_>>();
        let (background, tobe, why, pick) = (fresh(untagged(background)), fresh(untagged(summary)), fresh(why), fresh(pick));
        if part != Part::Act {
            if !question.is_empty() && label.is_empty() {
                bullets(ui, p, t(lang, "doc.summary"), &question);
            } else if !question.is_empty() {
                let (fg, bg) = theme::tone(&item.turn.actor, dark);
                egui::Frame::new().fill(bg).corner_radius(CornerRadius::same(10)).inner_margin(Margin::symmetric(12, 10)).show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    ui.label(RichText::new(label).color(fg).size(11.5).strong());
                    for line in &question { ui.add(egui::Label::new(prose(line, 15.5)).wrap()).on_hover_text(&ask); }
                });
            }
            bullets(ui, p, t(lang, "doc.background"), if no_background { &none } else { &background });
            bullets(ui, p, t(lang, "doc.changes"), &tobe);
            bullets(ui, p, t(lang, "doc.why"), if no_why { &none } else { &why });
            // The agent's pick and its reason stand apart: advice, not part of the question.
            if !pick.is_empty() {
                let heading = t(lang, "pick");
                egui::Frame::new().fill(p.accent.gamma_multiply(0.10)).corner_radius(CornerRadius::same(10)).inner_margin(Margin::symmetric(12, 8)).show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    ui.label(RichText::new(heading).color(p.accent).size(11.5).strong());
                    for line in &pick {
                        let text = line.strip_prefix(heading).and_then(|rest| rest.strip_prefix(':')).map(str::trim_start).unwrap_or(line);
                        ui.add(egui::Label::new(prose(text, 13.5)).wrap());
                    }
                });
            }
            ui.add_space(2.0);
        }
        if part == Part::Read { return; }
        // A command the human runs (e.g. a VPN login asking for an OTP): one click opens a terminal with it typed.
        if !item.done && !item.run.is_empty() {
            ui.label(RichText::new(&item.run).monospace().color(p.muted).size(11.5));
            ui.horizontal_wrapped(|ui| {
                if primary(ui, p, &format!("⌘ {}", t(lang, "run.button")), true).clicked() && !open_terminal(&item.run) {
                    ctx.copy_text(item.run.clone());
                    self.state.lock().unwrap().toast = Some((t(lang, "run.copied").to_string(), false, Instant::now()));
                }
                ui.label(RichText::new(t(lang, "run.help")).color(p.muted).size(11.5));
            });
        }
        if !item.done && !item.choices.is_empty() {
            // With the document's word on each option the choices stack, each over what it does.
            let about = doc.map(|doc| options(doc, &item.choices)).unwrap_or_default();
            if about.is_empty() { ui.horizontal_wrapped(|ui| self.choice_buttons(ui, ctx, p, item, busy, true, &[])); }
            else { self.choice_buttons(ui, ctx, p, item, busy, true, &about); }
        }
        if item.turn.actor == "you" && item.turn.kind == "answer" {
            // The agent's suggested answer fills the field until the human edits it; a new suggestion replaces an unedited one.
            let (draft, seed) = self.drafts.entry(item.id.clone()).or_insert_with(|| (item.suggest.clone(), item.suggest.clone()));
            if draft == seed && *seed != item.suggest { *draft = item.suggest.clone(); *seed = item.suggest.clone(); }
            // A fixed id: the automatic one shifts when the document arrives above it and the field would lose focus.
            let field = ui.add(egui::TextEdit::singleline(draft).id_salt(("reply", &item.id)).hint_text(t(lang, "reply.hint")).desired_width(f32::INFINITY).margin(Margin::symmetric(10, 7)))
                .on_hover_text(t(lang, "reply.help"));
            // Enter in the field sends, like the button; a single-line field loses focus on Enter.
            let entered = field.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
            let text = draft.trim().to_string();
            // The ticket sits beside the send button: the human checks it before answering.
            let send = ui.horizontal_wrapped(|ui| {
                let send = primary(ui, p, t(lang, "reply.send"), !busy && !text.is_empty()).clicked();
                ticket_buttons(ui, &tickets(item));
                send
            }).inner || (entered && !busy && !text.is_empty());
            if send {
                let (id, version, sent) = (item.id.clone(), item.version.clone(), t(lang, "reply.sent"));
                self.drafts.remove(&item.id);
                self.act(ctx, &id.clone(), move |s| client::post(s, "/api/item", json!({ "id": id, "version": version, "op": "reply", "text": text })).map(|_| sent.to_string()));
            }
        }
        if item.turn.actor == "you" && !item.turn.gate.is_empty() {
            if let Some(Ok(doc)) = artifact.filter(|a| a.as_ref().is_ok_and(|d| !d.sha.is_empty() && !d.gate.is_empty())) {
                let note = self.notes.entry(item.id.clone()).or_default();
                ui.add(egui::TextEdit::singleline(note).id_salt(("note", &item.id)).hint_text(t(lang, "approve.note")).desired_width(f32::INFINITY).margin(Margin::symmetric(10, 7)));
                if primary(ui, p, t(lang, "approve.button"), !busy).clicked() {
                    let body = json!({ "id": item.id, "version": item.version, "gate": doc.gate, "sha": doc.sha, "words": note.trim() });
                    let done = t(lang, "approve.done");
                    self.act(ctx, &item.id, move |s| client::post(s, "/api/approve", body).map(|_| done.to_string()));
                }
            }
        }
        if item.turn.actor == "blocked" && item.error.is_none()
            && primary(ui, p, &format!("⚡ {}", t(lang, "fix.button")), !busy).on_hover_text(t(lang, "fix.help")).clicked() {
            let (id, version) = (item.id.clone(), item.version.clone());
            self.act(ctx, &id.clone(), move |s| {
                let data = client::post(s, "/api/item", json!({ "id": id, "version": version, "op": "fix" }))?;
                let launch = data.get("launch").and_then(|v| v.as_str()).unwrap_or("queued").to_string();
                match launch.strip_prefix("failed: ") {
                    Some(reason) => Err(format!("{}{reason}", t(lang, "fix.failed"))),
                    None => Ok(t(lang, if launch == "started" { "fix.started" } else { "fix.queued" }).to_string()),
                }
            });
        }
        if !(item.turn.actor == "you" && item.turn.kind == "answer") {
            ui.horizontal_wrapped(|ui| ticket_buttons(ui, &tickets(item)));
        }
        if busy { ui.spinner(); }
        // The human's own memo on this item: kept with the app's settings, never sent to an agent.
        if !item.done {
            let memo = self.prefs.memos.entry(item.id.clone()).or_default();
            let dirty = &mut self.prefs_dirty;
            egui::CollapsingHeader::new(RichText::new(t(lang, "memo")).color(p.muted).size(12.0)).id_salt(("memo", &item.id))
                .default_open(!memo.trim().is_empty()).show(ui, |ui| {
                    let field = egui::TextEdit::multiline(memo).hint_text(t(lang, "memo.hint")).desired_rows(2).desired_width(f32::INFINITY).margin(Margin::symmetric(10, 7));
                    if ui.add(field).changed() { *dirty = true; }
                });
        }
        // The rest opens on demand: where the work stands in the sdlc loop, where the change lands, and the whole document.
        let phase = phase_of(item, artifact);
        if doc.is_some() || phase.is_some() || !item.repos.is_empty() {
            egui::CollapsingHeader::new(RichText::new(t(lang, "more")).color(p.muted).size(12.0)).id_salt(("more", &item.id)).show(ui, |ui| {
                if let Some(phase) = &phase { stepper(ui, p, lang, phase); }
                if !item.repos.is_empty() {
                    ui.label(RichText::new(format!("{} {}", t(lang, "repos"), item.repos.join(", "))).color(p.muted).size(12.0));
                }
                if let Some(doc) = doc {
                    ui.label(RichText::new(&doc.file).color(p.muted).size(11.0));
                    egui::ScrollArea::vertical().id_salt(("doc", &item.id)).max_height(320.0).show(ui, |ui| { ui.set_width(ui.available_width()); markdown(ui, p, &doc.markdown); });
                }
            });
        }
    }

    fn load_artifact(&self, ctx: &egui::Context, item: &Item) {
        let Some(session) = self.state.lock().unwrap().session.clone() else { return };
        let (state, ctx, id, key) = (self.state.clone(), ctx.clone(), item.id.clone(), artifact_key(item));
        state.lock().unwrap().artifacts.insert(key.clone(), Ok(Artifact { gate: String::new(), file: String::new(), markdown: String::new(), sha: String::new() }));
        std::thread::spawn(move || {
            let result = client::artifact(&session, &id);
            state.lock().unwrap().artifacts.insert(key, result);
            ctx.request_repaint();
        });
    }
}

/// The decision brief as [call, gist, background, why], a few short lines each.
/// At a glance carries the four lines by label; older documents fall back to their sections.
fn glance(doc: &Artifact) -> [Vec<String>; 5] {
    let sections = sections(&doc.markdown);
    let body = |names: &[&str]| sections.iter().find(|(title, _)| names.iter().any(|n| title.eq_ignore_ascii_case(n))).map(|(_, b)| b.as_str()).unwrap_or("");
    let glance = body(&["At a glance"]);
    let field = |label: &str| labeled(glance, label);
    let or = |line: Option<String>, names: &[&str], limit: usize| line.map(|l| vec![l]).unwrap_or_else(|| points(body(names), limit));
    let questions = points(body(&["Questions for you", "Out of scope and open questions"]), 3);
    let decide = field("Your call").map(|l| vec![l]).filter(|_| questions.is_empty()).unwrap_or(questions);
    let pick = field("AI pick").map(|l| vec![l]).unwrap_or_default();
    [decide, or(field("What changes"), &["Summary"], 1), or(field("Background"), &["Understanding"], 1), or(field("Why"), &["Why this came up"], 1), pick]
}

/// What each offered answer does, from the document's numbered Options list (`1. **label** — what it does`),
/// in the choices' order, each line matched to its choice by the bold label, not by place: a list in another
/// order must not put one option's words under another's button. Empty unless every choice has its own line
/// and the list has no others.
fn options(doc: &Artifact, choices: &[String]) -> Vec<String> {
    let sections = sections(&doc.markdown);
    let Some((_, body)) = sections.iter().find(|(title, _)| { let title = title.to_lowercase(); title.starts_with("options") || title.starts_with("선택지") }) else { return Vec::new() };
    let norm = |text: &str| text.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase();
    // (label, what it does) per numbered line; a line without a bold label has no label to match.
    let lines: Vec<(Option<String>, String)> = body.lines().filter_map(|line| {
        let (number, rest) = line.trim_start().split_once(". ")?;
        if number.is_empty() || !number.chars().all(|c| c.is_ascii_digit()) { return None; }
        let (label, after) = match rest.trim_start().strip_prefix("**").and_then(|bold| bold.split_once("**")) {
            Some((label, after)) => (Some(norm(label)), after),
            None => (None, rest),
        };
        let about = after.split_once(" — ").or_else(|| after.split_once(" - ")).map(|(_, about)| about).unwrap_or("");
        Some((label, clip(&about.replace("**", "").replace('`', ""), 240)))
    }).collect();
    if lines.len() != choices.len() { return Vec::new(); }
    choices.iter().map(|choice| {
        let choice = norm(choice);
        lines.iter().find(|(label, _)| label.as_deref() == Some(choice.as_str())).map(|(_, about)| about.clone())
    }).collect::<Option<Vec<_>>>().unwrap_or_default()
}

const PHASES: [&str; 6] = ["intent", "plan", "build", "evidence", "deliver", "done"];

/// The sdlc phase of an item, or of the ticket a brief is about (its At a glance `Phase:` line).
fn phase_of(item: &Item, artifact: Option<&Result<Artifact, String>>) -> Option<String> {
    let own = item.sdlc.as_ref().map(|s| s.phase.clone()).filter(|p| !p.is_empty());
    own.or_else(|| {
        let doc = artifact?.as_ref().ok()?;
        let sections = sections(&doc.markdown);
        let glance = sections.iter().find(|(title, _)| title.eq_ignore_ascii_case("At a glance"))?;
        labeled(&glance.1, "Phase")
    }).map(|p| p.trim().to_lowercase())
}

fn stepper(ui: &mut egui::Ui, p: &theme::Palette, lang: Lang, phase: &str) {
    let Some(now) = PHASES.iter().position(|name| *name == phase) else {
        ui.label(RichText::new(t(lang, if phase == "legacy" { "phase.legacy" } else { "phase.now" })).color(p.muted).size(11.5));
        return;
    };
    ui.horizontal_wrapped(|ui| {
        ui.spacing_mut().item_spacing.x = 4.0;
        for (i, name) in PHASES.iter().enumerate() {
            let label = t(lang, &format!("phase.{name}"));
            if i == now {
                egui::Frame::new().fill(p.accent).corner_radius(CornerRadius::same(10)).inner_margin(Margin::symmetric(9, 3))
                    .show(ui, |ui| ui.label(RichText::new(label).color(p.on_accent).size(12.0).strong()));
            } else if i < now {
                egui::Frame::new().fill(p.accent.gamma_multiply(0.14)).corner_radius(CornerRadius::same(10)).inner_margin(Margin::symmetric(8, 3))
                    .show(ui, |ui| ui.label(RichText::new(format!("✓ {label}")).color(p.accent).size(11.5)));
            } else {
                egui::Frame::new().stroke(Stroke::new(1.0, p.stroke)).corner_radius(CornerRadius::same(10)).inner_margin(Margin::symmetric(8, 3))
                    .show(ui, |ui| ui.label(RichText::new(label).color(p.muted).size(11.5)));
            }
            if i + 1 < PHASES.len() { ui.label(RichText::new("›").color(if i < now { p.accent } else { p.muted }).size(12.0)); }
        }
    });
}

/// Reading text: lines stand a little apart, as on a page.
fn prose(text: &str, size: f32) -> RichText { RichText::new(text).size(size).line_height(Some(size * 1.55)) }

/// The top of a decision's page: where it belongs as a running head, what kind of decision it is, then its title.
fn heading(ui: &mut egui::Ui, p: &theme::Palette, dark: bool, lang: Lang, item: &Item) {
    ui.horizontal(|ui| {
        ui.label(RichText::new(meta_of(item)).color(p.muted).size(12.0));
        // Decisions the agent recommends no answer for stand out; the rest stay quiet.
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| match item.turn.kind.as_str() {
            "answer" if must_decide(item) => pill(ui, t(lang, "decide.yours"), "you", dark),
            "answer" => pill(ui, t(lang, "decide.suggested"), "", dark),
            _ => pill(ui, status_label(lang, item), &item.turn.actor, dark),
        });
    });
    ui.add(egui::Label::new(RichText::new(&item.title).size(19.0).strong().line_height(Some(27.0))).wrap());
    ui.add_space(6.0);
}

/// The project folder and the ticket, as one muted line.
fn meta_of(item: &Item) -> String {
    let mut meta = Vec::new();
    if let Some(project) = item.project.as_deref().filter(|p| !p.is_empty()) {
        meta.push(PathBuf::from(project).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| project.to_string()));
    }
    if let Some(link) = &item.link { meta.push(link.label.clone()); }
    meta.join(" · ")
}

/// One line for an item: a dot in its actor's colour and the title, cut to fit; the hint shows on hover.
/// Returns true when the line is clicked.
fn line(ui: &mut egui::Ui, p: &theme::Palette, color: Color32, item: &Item, hint: &str) -> bool {
    let row = ui.horizontal(|ui| {
        let (rect, _) = ui.allocate_exact_size(egui::vec2(8.0, 8.0), Sense::hover());
        ui.painter().circle_filled(rect.center(), 4.0, color);
        ui.add(egui::Label::new(RichText::new(&item.title).color(p.text).size(13.5)).truncate().selectable(false));
    }).response;
    // The whole width answers the click, not only the text.
    let rect = egui::Rect::from_x_y_ranges(ui.max_rect().x_range(), row.rect.y_range());
    ui.interact(rect, egui::Id::new(("line", &item.id)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand).on_hover_text(hint).clicked()
}

fn ticket_buttons(ui: &mut egui::Ui, tickets: &[(String, String)]) {
    for (label, url) in tickets {
        if ui.button(format!("↗ {label}")).on_hover_text(url).clicked() { open_url(url); }
    }
}

fn bullets(ui: &mut egui::Ui, p: &theme::Palette, title: &str, lines: &[String]) {
    if lines.is_empty() { return; }
    ui.add_space(2.0);
    ui.label(RichText::new(title).color(p.accent).size(11.5).strong());
    for line in lines { ui.add(egui::Label::new(prose(line, 13.5)).wrap()); }
}

fn sections(markdown: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for line in markdown.lines() {
        if let Some(title) = line.strip_prefix("## ") { out.push((title.trim().to_string(), String::new())); }
        else if let Some((_, body)) = out.last_mut() { body.push_str(line); body.push('\n'); }
    }
    out
}

/// The text after `**Label:**` in a section, unless it says none.
fn labeled(body: &str, label: &str) -> Option<String> {
    body.lines().find_map(|line| {
        let rest = line.trim_start().strip_prefix("- ")?.trim_start().strip_prefix(&format!("**{label}:**"))?;
        let text = rest.replace("**", "").replace('`', "").trim().to_string();
        (!text.is_empty() && !text.eq_ignore_ascii_case("none") && !text.starts_with('<')).then(|| clip(&text, 320))
    })
}

/// The first few points of a section as plain one-liners: bullets, else sentences.
fn points(body: &str, limit: usize) -> Vec<String> {
    let plain = |text: &str| text.replace("**", "").replace('`', "").trim().to_string();
    let raw: Vec<String> = body.lines()
        .filter_map(|l| l.trim_start().strip_prefix("- ").or_else(|| l.trim_start().strip_prefix("* ")))
        .map(plain).collect();
    let bullets: Vec<String> = raw.iter().filter(|l| !l.is_empty() && !l.eq_ignore_ascii_case("none")).cloned().collect();
    // A list that only says "none" means nothing to show, not "read the prose instead".
    let lines = if raw.is_empty() {
        let text = plain(&body.lines().map(str::trim).filter(|l| !l.starts_with('|') && !l.starts_with("<!--") && *l != "---").collect::<Vec<_>>().join(" "));
        text.split_inclusive(['.', '。']).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
    } else { bullets };
    lines.into_iter().take(limit).map(|l| clip(&l, 140)).collect()
}

/// Drops a leading `…(AS-IS):` or `…(TO-BE):` tag: the heading over the line already says which it is.
fn untag(line: String) -> String {
    for tag in ["(AS-IS):", "(TO-BE):"] {
        if let Some((lead, rest)) = line.split_once(tag) {
            if lead.chars().count() <= 12 { return rest.trim_start().to_string(); }
        }
    }
    line
}

fn clip(text: &str, max: usize) -> String {
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.chars().count() <= max { text } else { format!("{}…", text.chars().take(max).collect::<String>().trim_end()) }
}

fn has_document(item: &Item) -> bool {
    !item.done && (!item.brief.is_empty() || item.sdlc.is_some() && item.project.as_deref().is_some_and(|p| !p.is_empty()) && item.error.is_none())
}

/// The tickets behind an item: its link first, then other ticket URLs in its question or action.
fn tickets(item: &Item) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    if let Some(link) = item.link.as_ref().filter(|l| l.url.starts_with("http")) { out.push((link.label.clone(), link.url.clone())); }
    let text = format!("{} {}", item.waiting, item.sdlc.as_ref().map(|s| s.action.as_str()).unwrap_or(""));
    for word in text.split(|c: char| c.is_whitespace() || "()<>\"'".contains(c)) {
        let url = word.trim_end_matches(['.', ',', ';', ')']);
        if (url.starts_with("https://") || url.starts_with("http://")) && url.contains("/browse/") && !out.iter().any(|(_, u)| u == url) {
            let label = url.rsplit('/').next().unwrap_or(url).to_string();
            out.push((label, url.to_string()));
        }
    }
    out
}

/// A document is cached per item version, so an edited intent or plan is fetched again.
fn artifact_key(item: &Item) -> String { format!("{}:{}", item.id, item.version) }

struct Args { session: PathBuf, kit: PathBuf, node: String, lang: String }

fn args() -> Result<Args, String> {
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).map(PathBuf::from).unwrap_or_default();
    let todo = std::env::var_os("SDLC_TODO").map(PathBuf::from).unwrap_or_else(|| home.join(".sdlc").join("todo.md"));
    let mut parsed = Args {
        session: std::env::var_os("SDLC_TODO_SESSION").map(PathBuf::from)
            .unwrap_or_else(|| todo.parent().map(|d| d.join("todo-web.json")).unwrap_or_default()),
        // An app bundle names the kit and node in its Info.plist environment; built in place,
        // the binary sits at <kit>/todo/app/target/release/.
        kit: std::env::var_os("SDLC_TODO_KIT").map(PathBuf::from)
            .or_else(|| std::env::current_exe().ok().and_then(|exe| exe.ancestors().nth(5).map(PathBuf::from)))
            .unwrap_or_default(),
        node: std::env::var("SDLC_TODO_NODE").unwrap_or_else(|_| "node".into()),
        lang: std::env::var("SDLC_TODO_LANG").unwrap_or_else(|_| "en".into()),
    };
    let mut list = std::env::args().skip(1);
    while let Some(flag) = list.next() {
        let value = list.next().ok_or_else(|| format!("missing value for {flag}"))?;
        match flag.as_str() {
            "--session" => parsed.session = value.into(),
            "--kit" => parsed.kit = value.into(),
            "--node" => parsed.node = value,
            "--lang" => parsed.lang = value,
            _ => return Err(format!("unknown option: {flag}\nusage: sdlc-todo [--session FILE] [--kit DIR] [--node PATH] [--lang en|ko]")),
        }
    }
    if !parsed.kit.join("todo").join("todo.mjs").is_file() { return Err(format!("no todo/todo.mjs under --kit {}", parsed.kit.display())); }
    Ok(parsed)
}

fn main() -> Result<(), String> {
    // Without a sender, mac-notification-sys asks AppleScript for application "use_default" before the
    // first notification, and macOS answers with a "Where is use_default?" chooser. Name the sender up front.
    #[cfg(target_os = "macos")]
    {
        let bundled = std::env::current_exe().is_ok_and(|exe| exe.to_string_lossy().contains(".app/Contents/MacOS/"));
        let _ = notify_rust::set_application(if bundled { "dev.sdlc-kit.todo" } else { "com.apple.Terminal" });
    }
    let args = args()?;
    let lang = Lang::parse(&args.lang);
    let launcher = Launcher { session_file: args.session, kit: args.kit, node: args.node, lang: args.lang };
    // Without an icon eframe sets its own default as the window and Dock icon, over the bundle's.
    let icon = eframe::icon_data::from_png_bytes(include_bytes!("../AppIcon.png")).expect("valid app icon");
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_title(t(lang, "title")).with_icon(icon).with_inner_size([600.0, 820.0]).with_min_inner_size([420.0, 480.0]),
        ..Default::default()
    };
    eframe::run_native("sdlc-todo", options, Box::new(move |cc| Ok(Box::new(App::new(cc, launcher, lang))))).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use client::{Link, Turn};

    fn item(id: &str, actor: &str, kind: &str) -> Item {
        Item { id: id.into(), title: id.into(), turn: Turn { actor: actor.into(), kind: kind.into(), gate: String::new() }, ..Default::default() }
    }
    fn ids(items: &[Item]) -> Vec<&str> { decision_queue(items).into_iter().map(|i| i.id.as_str()).collect() }

    #[test]
    fn decisions_without_a_recommendation_lead_the_queue() {
        let suggested = Item { suggest: "yes".into(), ..item("suggested", "you", "answer") };
        let picked = Item { choices: vec!["a".into(), "b".into()], pick: Some(1), ..item("picked", "you", "answer") };
        let pinned = Item { pin: true, ..item("pinned", "you", "answer") };
        let done = Item { done: true, ..item("done", "you", "answer") };
        let items = [suggested, picked, item("working", "agent", "agent"), item("blocked", "blocked", "blocked"),
            item("open", "you", "answer"), item("gate", "you", "approve-plan"), pinned, done];
        assert_eq!(ids(&items), ["blocked", "open", "gate", "suggested", "picked"]);
    }

    #[test]
    fn decisions_for_one_ticket_stay_together() {
        let on = |mut item: Item, url: &str| { item.link = Some(Link { label: url.into(), url: url.into() }); item };
        let items = [
            Item { suggest: "yes".into(), ..item("other", "you", "answer") },
            Item { suggest: "yes".into(), ..on(item("same", "you", "answer"), "https://t/browse/A-1") },
            on(item("first", "you", "approve-intent"), "https://t/browse/A-1"),
            Item { choices: vec!["a".into(), "b".into()], pick: Some(1), ..on(item("choice", "you", "answer"), "https://t/browse/A-1") },
        ];
        // The ticket leads because one of its decisions has no recommendation; the one offering choices shows first.
        assert_eq!(ids(&items), ["choice", "first", "same", "other"]);
    }

    #[test]
    fn option_notes_come_from_the_documents_numbered_list() {
        let doc = |markdown: &str| Artifact { gate: String::new(), file: String::new(), markdown: markdown.into(), sha: "x".into() };
        let brief = doc("# D\n\n## At a glance\n- **Your call:** go?\n\n## 선택지 (번호로 답)\n1. **승인** (AI 권장) — 계획대로 `build`.\n2. **보류** — 진행하지 않고 대기.\n\n## Next\n1. unrelated — no\n");
        let choices = |labels: &[&str]| labels.iter().map(|l| l.to_string()).collect::<Vec<_>>();
        assert_eq!(options(&brief, &choices(&["승인", "보류"])), ["계획대로 build.", "진행하지 않고 대기."]);
        assert_eq!(options(&doc("## Options\n1. **a** - first\n2. **b**\n"), &choices(&["a", "b"])), ["first", ""]);
        // A list that does not match the choices one to one says nothing rather than mislabel them.
        assert!(options(&brief, &choices(&["승인", "보류", "취소"])).is_empty());
        assert!(options(&doc("## Summary\n1. a — b\n"), &choices(&["a"])).is_empty());
    }

    #[test]
    fn option_notes_follow_the_choices_not_the_lists_order() {
        let doc = |markdown: &str| Artifact { gate: String::new(), file: String::new(), markdown: markdown.into(), sha: "x".into() };
        let choices = |labels: &[&str]| labels.iter().map(|l| l.to_string()).collect::<Vec<_>>();
        let swapped = doc("## Options\n1. **Hold  it** — wait for QA.\n2. **Ship** (AI pick) — merge now.\n");
        // Labels match after trimming, collapsing spaces and ignoring case.
        assert_eq!(options(&swapped, &choices(&["ship", " Hold it "])), ["merge now.", "wait for QA."]);
        // A choice with no line of its own: nothing, not a guess by place.
        assert!(options(&swapped, &choices(&["Ship", "Cancel"])).is_empty());
    }

    #[test]
    fn a_leading_as_is_or_to_be_tag_is_dropped() {
        assert_eq!(untag("지금(AS-IS): 열쇠가 넓다.".into()), "열쇠가 넓다.");
        assert_eq!(untag("Planned (TO-BE): narrow it.".into()), "narrow it.");
        // Only a short lead is a tag; the words inside a sentence stay.
        assert_eq!(untag("Today the key opens every file (AS-IS): too wide.".into()), "Today the key opens every file (AS-IS): too wide.");
    }

    #[test]
    fn focus_follows_the_decision_then_takes_the_next_one() {
        assert_eq!(settle(None, 0, &[]), None);
        assert_eq!(settle(None, 0, &["a", "b"]), Some(0));
        // A new decision ahead does not move the one on screen.
        assert_eq!(settle(Some("b"), 1, &["new", "a", "b"]), Some(2));
        // Answered: the decision now at its place shows; the last one falls back to the new end.
        assert_eq!(settle(Some("a"), 0, &["b", "c"]), Some(0));
        assert_eq!(settle(Some("c"), 2, &["a", "b"]), Some(1));
    }
}
