//! sdlc-todo: a small tray app for the sdlc-kit to-do. It never edits todo.md itself; every
//! change goes through the same web API as the browser page, so the TUI, page and app agree.
#![cfg_attr(windows, windows_subsystem = "windows")]
mod client;
mod i18n;
mod theme;

use client::{Artifact, Item, Launcher, Model, Session};
use eframe::egui::{self, Align, Color32, CornerRadius, Layout, Margin, RichText, Sense, Stroke, ViewportCommand};
use i18n::{t, Lang};
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
    open: HashSet<String>,
    closed: HashSet<String>,
    drafts: HashMap<String, String>,
    notes: HashMap<String, String>,
    tray: Option<TrayIcon>,
    badge: Option<usize>,
}

fn needs_you(item: &Item) -> bool { !item.done && matches!(item.turn.actor.as_str(), "you" | "blocked") }

fn status_label(lang: Lang, item: &Item) -> &'static str {
    match item.turn.kind.as_str() {
        "approve-intent" => t(lang, "status.approve-intent"),
        "approve-plan" => t(lang, "status.approve-plan"),
        "answer" => t(lang, "status.answer"),
        "agent" => t(lang, "status.agent"),
        "handoff" => t(lang, "status.handoff"),
        "blocked" => t(lang, "status.blocked"),
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
        theme::install(&cc.egui_ctx);
        let state: State = Arc::new(Mutex::new(Shared {
            model: None, conn: Conn::Connecting, session: None, child: None, toast: None,
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
        App { state, lang, tab: Tab::Focus, open: HashSet::new(), closed: HashSet::new(), drafts: HashMap::new(), notes: HashMap::new(), tray, badge: None }
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

        let dark = ctx.style().visuals.dark_mode;
        let p = theme::palette(dark);
        egui::CentralPanel::default()
            .frame(egui::Frame::new().fill(p.bg).inner_margin(Margin::symmetric(18, 16)))
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    ui.heading(RichText::new(t(lang, "title")).strong());
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        let (color, text) = match &conn {
                            Conn::Live => (Color32::from_rgb(34, 197, 94), t(lang, "live")),
                            Conn::Connecting => (Color32::from_rgb(245, 158, 11), t(lang, "connecting")),
                            Conn::Offline(_) => (Color32::from_rgb(239, 68, 68), t(lang, "offline")),
                        };
                        ui.label(RichText::new(text).color(p.muted).size(12.0));
                        let (rect, _) = ui.allocate_exact_size(egui::vec2(8.0, 8.0), Sense::hover());
                        ui.painter().circle_filled(rect.center(), 4.0, color);
                    });
                });
                if let Conn::Offline(reason) = &conn {
                    ui.label(RichText::new(reason).color(theme::tone("blocked", dark).0).size(12.0));
                }
                ui.add_space(4.0);
                let count = |actor: &str| model.items.iter().filter(|i| i.turn.actor == actor).count();
                ui.horizontal(|ui| {
                    for (actor, key) in [("you", "you"), ("agent", "agent"), ("blocked", "blocked"), ("done", "done")] {
                        pill(ui, &format!("{} {}", t(lang, key), count(actor)), actor, dark);
                    }
                });
                ui.add_space(10.0);
                egui::Frame::new().fill(p.card).stroke(Stroke::new(1.0, p.stroke)).corner_radius(CornerRadius::same(10))
                    .inner_margin(Margin::same(3)).show(ui, |ui| {
                        ui.horizontal(|ui| {
                            ui.spacing_mut().item_spacing.x = 2.0;
                            for (tab, key) in [(Tab::Focus, "tab.focus"), (Tab::Agent, "tab.agent"), (Tab::All, "tab.all"), (Tab::Done, "tab.done")] {
                                let selected = self.tab == tab;
                                let text = RichText::new(t(lang, key)).color(if selected { p.on_accent } else { p.muted }).strong();
                                let button = egui::Button::new(text).fill(if selected { p.accent } else { Color32::TRANSPARENT })
                                    .stroke(Stroke::NONE).corner_radius(CornerRadius::same(8));
                                if ui.add(button).clicked() { self.tab = tab; }
                            }
                        });
                    });
                ui.add_space(10.0);

                let shown: Vec<&Item> = model.items.iter().filter(|i| match self.tab {
                    Tab::Focus => needs_you(i),
                    Tab::Agent => !i.done && i.turn.actor == "agent",
                    Tab::All => !i.done,
                    Tab::Done => i.done,
                }).collect();
                let toast_height = if toast.is_some() { 44.0 } else { 0.0 };
                egui::ScrollArea::vertical().max_height(ui.available_height() - toast_height).auto_shrink([false, false]).show(ui, |ui| {
                    ui.add_space(1.0);
                    if shown.is_empty() && conn == Conn::Live {
                        ui.add_space(40.0);
                        ui.vertical_centered(|ui| ui.label(RichText::new(t(lang, if self.tab == Tab::Focus { "empty.focus" } else { "empty" })).color(p.muted)));
                    }
                    for item in shown {
                        self.card(ui, ctx, &p, dark, item, busy.contains(&item.id), artifacts.get(&artifact_key(item)));
                        ui.add_space(8.0);
                    }
                });
                if let Some((text, error, _)) = toast {
                    let (fg, bg) = if error { theme::tone("blocked", dark) } else { (p.text, p.card) };
                    egui::Frame::new().fill(bg).stroke(Stroke::new(1.0, p.stroke)).corner_radius(CornerRadius::same(10))
                        .inner_margin(Margin::symmetric(12, 8)).show(ui, |ui| { ui.set_width(ui.available_width()); ui.label(RichText::new(text).color(fg)); });
                }
            });
    }
}

impl App {
    #[allow(clippy::too_many_arguments)]
    fn card(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, p: &theme::Palette, dark: bool, item: &Item, busy: bool, artifact: Option<&Result<Artifact, String>>) {
        let lang = self.lang;
        // Items that need a decision open by default; others open on demand.
        let expanded = if needs_you(item) { !self.closed.contains(&item.id) } else { self.open.contains(&item.id) };
        let id = item.id.clone();
        theme::card(p).show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal(|ui| {
                pill(ui, status_label(lang, item), &item.turn.actor, dark);
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if let Some(sdlc) = &item.sdlc { if !sdlc.phase.is_empty() { ui.label(RichText::new(&sdlc.phase).color(p.muted).size(11.5)); } }
                });
            });
            ui.add_space(2.0);
            let header = ui.add(egui::Label::new(RichText::new(&item.title).size(14.5).strong()).sense(Sense::click()))
                .on_hover_cursor(egui::CursorIcon::PointingHand);
            let mut meta = Vec::new();
            if let Some(project) = item.project.as_deref().filter(|p| !p.is_empty()) {
                meta.push(PathBuf::from(project).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| project.to_string()));
            }
            if let Some(link) = &item.link { meta.push(link.label.clone()); }
            if !meta.is_empty() { ui.label(RichText::new(meta.join(" · ")).color(p.muted).size(12.0)); }
            if header.clicked() {
                let set = if needs_you(item) { &mut self.closed } else { &mut self.open };
                if !set.remove(&id) { set.insert(id.clone()); }
            }
            if expanded { ui.add_space(6.0); self.details(ui, ctx, p, item, busy, artifact); }
        });
    }

    fn details(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, p: &theme::Palette, item: &Item, busy: bool, artifact: Option<&Result<Artifact, String>>) {
        let lang = self.lang;
        let dark = ui.visuals().dark_mode;
        let action = item.sdlc.as_ref().map(|s| s.action.clone()).unwrap_or_default();
        // The question or problem comes first: it is what the human decides on.
        let (label, ask) = match item.turn.actor.as_str() {
            // A gate's sdlc action is a command for agents; say what it asks in words.
            "you" if !item.turn.gate.is_empty() && item.waiting.is_empty() => (t(lang, "waits"), t(lang, if item.turn.gate == "plan" { "ask.plan" } else { "ask.intent" }).to_string()),
            "you" => (t(lang, "waits"), if item.waiting.is_empty() { action.clone() } else { item.waiting.clone() }),
            "blocked" => (t(lang, "problem"), item.error.clone().unwrap_or(action.clone())),
            _ => ("", String::new()),
        };
        if !ask.is_empty() {
            let (fg, bg) = theme::tone(&item.turn.actor, dark);
            egui::Frame::new().fill(bg).corner_radius(CornerRadius::same(10)).inner_margin(Margin::symmetric(12, 10)).show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.label(RichText::new(label).color(fg).size(11.5).strong());
                ui.label(RichText::new(clip(&ask, 160)).size(13.5)).on_hover_text(&ask);
            });
        }
        // Background and intent come from the work document (intent.md or PLAN.md).
        if has_document(item) {
            match artifact {
                None => self.load_artifact(ctx, item),
                Some(Err(error)) => { ui.label(RichText::new(error).color(theme::tone("blocked", dark).0).size(12.0)); }
                Some(Ok(doc)) if doc.sha.is_empty() => { ui.label(RichText::new(t(lang, "doc.loading")).color(p.muted).size(12.0)); }
                Some(Ok(doc)) => self.document(ui, p, item, doc),
            }
        }
        ui.add_space(2.0);
        if item.turn.actor == "you" && item.turn.kind == "answer" {
            let draft = self.drafts.entry(item.id.clone()).or_default();
            ui.add(egui::TextEdit::singleline(draft).hint_text(t(lang, "reply.hint")).desired_width(f32::INFINITY).margin(Margin::symmetric(10, 7)));
            ui.label(RichText::new(t(lang, "reply.help")).color(p.muted).size(11.5));
            let text = draft.trim().to_string();
            if primary(ui, p, t(lang, "reply.send"), !busy && !text.is_empty()).clicked() {
                let (id, version, sent) = (item.id.clone(), item.version.clone(), t(lang, "reply.sent"));
                self.drafts.remove(&item.id);
                self.act(ctx, &id.clone(), move |s| client::post(s, "/api/item", json!({ "id": id, "version": version, "op": "reply", "text": text })).map(|_| sent.to_string()));
            }
        }
        if item.turn.actor == "you" && !item.turn.gate.is_empty() {
            if let Some(Ok(doc)) = artifact.filter(|a| a.as_ref().is_ok_and(|d| !d.sha.is_empty() && !d.gate.is_empty())) {
                let note = self.notes.entry(item.id.clone()).or_default();
                ui.add(egui::TextEdit::singleline(note).hint_text(t(lang, "approve.note")).desired_width(f32::INFINITY).margin(Margin::symmetric(10, 7)));
                if primary(ui, p, t(lang, "approve.button"), !busy).clicked() {
                    let body = json!({ "id": item.id, "version": item.version, "gate": doc.gate, "sha": doc.sha, "words": note.trim() });
                    let done = t(lang, "approve.done");
                    self.act(ctx, &item.id, move |s| client::post(s, "/api/approve", body).map(|_| done.to_string()));
                }
            }
        }
        if item.turn.actor == "blocked" && item.error.is_none() {
            ui.label(RichText::new(t(lang, "fix.help")).color(p.muted).size(12.0));
            if primary(ui, p, &format!("⚡ {}", t(lang, "fix.button")), !busy).clicked() {
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
        }
        let tickets = tickets(item);
        if !tickets.is_empty() {
            ui.horizontal_wrapped(|ui| {
                for (label, url) in &tickets {
                    if ui.button(format!("↗ {label}")).on_hover_text(url).clicked() { open_url(url); }
                }
            });
        }
        if busy { ui.spinner(); }
    }

    /// The decision brief: what to decide, the gist and why, a few short lines each; the rest folds away.
    fn document(&mut self, ui: &mut egui::Ui, p: &theme::Palette, item: &Item, doc: &Artifact) {
        let lang = self.lang;
        let sections = sections(&doc.markdown);
        let body = |names: &[&str]| sections.iter().find(|(title, _)| names.iter().any(|n| title.eq_ignore_ascii_case(n))).map(|(_, b)| b.as_str()).unwrap_or("");
        // At a glance carries the four lines by label; older documents fall back to their sections.
        let glance = body(&["At a glance"]);
        let field = |label: &str| labeled(glance, label);
        let or = |line: Option<String>, names: &[&str], limit: usize| line.map(|l| vec![l]).unwrap_or_else(|| points(body(names), limit));
        let questions = points(body(&["Questions for you", "Out of scope and open questions"]), 3);
        let decide = field("Your call").map(|l| vec![l]).filter(|_| questions.is_empty()).unwrap_or(questions);
        let brief = [
            ("doc.questions", decide),
            ("doc.summary", or(field("What changes"), &["Summary"], 1)),
            ("doc.background", or(field("Background"), &["Understanding"], 1)),
            ("doc.why", or(field("Why"), &["Why this came up"], 1)),
        ];
        for (key, lines) in brief.iter().filter(|(_, lines)| !lines.is_empty()) {
            ui.add_space(2.0);
            ui.label(RichText::new(t(lang, key)).color(p.accent).size(11.5).strong());
            for line in lines {
                ui.horizontal_top(|ui| { ui.label(RichText::new("•").color(p.accent)); ui.add(egui::Label::new(RichText::new(line).size(13.0)).wrap()); });
            }
        }
        egui::CollapsingHeader::new(RichText::new(t(lang, "doc.full")).color(p.muted).size(12.0))
            .id_salt(("full", &item.id))
            .show(ui, |ui| {
                ui.label(RichText::new(&doc.file).color(p.muted).size(11.0));
                egui::ScrollArea::vertical().id_salt(("doc", &item.id)).max_height(320.0).show(ui, |ui| { ui.set_width(ui.available_width()); markdown(ui, p, &doc.markdown); });
            });
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
        (!text.is_empty() && !text.eq_ignore_ascii_case("none") && !text.starts_with('<')).then(|| clip(&text, 160))
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

fn clip(text: &str, max: usize) -> String {
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.chars().count() <= max { text } else { format!("{}…", text.chars().take(max).collect::<String>().trim_end()) }
}

fn has_document(item: &Item) -> bool {
    !item.done && item.sdlc.is_some() && item.project.as_deref().is_some_and(|p| !p.is_empty()) && item.error.is_none()
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
    let args = args()?;
    let lang = Lang::parse(&args.lang);
    let launcher = Launcher { session_file: args.session, kit: args.kit, node: args.node, lang: args.lang };
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_title(t(lang, "title")).with_inner_size([440.0, 680.0]).with_min_inner_size([360.0, 420.0]),
        ..Default::default()
    };
    eframe::run_native("sdlc-todo", options, Box::new(move |cc| Ok(Box::new(App::new(cc, launcher, lang))))).map_err(|e| e.to_string())
}
