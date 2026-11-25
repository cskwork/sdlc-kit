//! Reads each open sdlc item's status from sdlc.sh, a few at a time, and records what changed.
use super::core::{self, Fail, Item, Kind, Reading, Sdlc};
use super::json::{self, Json};
use super::{helper, js, run};
use std::sync::atomic::{AtomicUsize, Ordering};

const READERS: usize = 6;

pub fn script(kit: &str) -> String { js::join(kit, &["sdlc.sh"]) }

/// `sdlc.sh status <slug> --json` in the item's project.
pub fn status(kit: &str, project: &str, slug: &str) -> Result<String, run::Failed> {
    let cwd = core::project_path(project).map_err(|e| run::Failed { message: e.message, stderr: String::new() })?;
    let cwd = run::native_path(&cwd)?;
    run::exec_file("bash", &[&script(kit), "status", slug, "--json"], Some(&cwd))
}

fn text(value: Option<&Json>) -> String {
    match value { Some(Json::Str(text)) => text.lossy(), Some(Json::Null) | None => String::new(), Some(other) => other.stringify() }
}
fn feature(stdout: &str, slug: &str) -> Option<Sdlc> {
    let value = json::parse(stdout)?;
    let Json::Arr(features) = value.get("features")? else { return None };
    let current = features.iter().find(|f| matches!(f.get("slug"), Some(Json::Str(s)) if s.lossy() == slug))?;
    let state = text(current.get("state"));
    (!state.is_empty()).then(|| Sdlc { slug: slug.into(), phase: text(current.get("phase")), state, action: text(current.get("action")) })
}
fn read(item: &Item, kit: &str) -> Result<Option<Reading>, Fail> {
    let Some(previous) = item.sdlc.clone() else { return Ok(None) };
    let (current, error) = match status(kit, &item.project, &previous.slug) {
        Ok(stdout) => match feature(&stdout, &previous.slug) {
            Some(current) => (Some(current), String::new()),
            // The words land in todo.md, where the CLI records V8's: ask Node for exactly those.
            None => (None, helper::status_error(&stdout, &previous.slug)?),
        },
        Err(failed) => (None, failed.text()),
    };
    let current = current.unwrap_or_else(|| Sdlc { state: "BLOCKED".into(), action: one_line(&error), ..previous.clone() });
    Ok(Some(Reading { id: item.id.clone(), project: item.project.clone(), previous, current }))
}
/// Runs of line breaks as one space, trimmed.
fn one_line(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_break = false;
    for c in text.chars() {
        let is_break = matches!(c, '\r' | '\n');
        if !is_break { out.push(c); } else if !in_break { out.push(' '); }
        in_break = is_break;
    }
    js::trim(&out).into()
}
fn readings(file: &str, kit: &str, only: &str) -> Result<Vec<Reading>, Fail> {
    let items = core::scoped(file, only)?;
    let next = AtomicUsize::new(0);
    let work = || {
        let mut done = Vec::new();
        while let Some((at, item)) = { let at = next.fetch_add(1, Ordering::SeqCst); items.get(at).map(|item| (at, item)) } { done.push((at, read(item, kit))); }
        done
    };
    let results: Vec<Result<Option<Reading>, Fail>> = std::thread::scope(|scope| {
        // This thread reads too, so every item is read even when no other thread can start.
        let readers: Vec<_> = (1..READERS.min(items.len())).filter_map(|_| std::thread::Builder::new().spawn_scoped(scope, work).ok()).collect();
        let mut all = work();
        all.extend(readers.into_iter().flat_map(|r| r.join().unwrap_or_else(|_| vec![(0, Err(Fail::new("a status reader failed")))])));
        all.sort_by_key(|(at, _)| *at);
        all.into_iter().map(|(_, result)| result).collect()
    });
    results.into_iter().filter_map(Result::transpose).collect()
}
/// core.sync: `only` limits the status calls to one item id.
pub fn sync(list: &core::List, kit: &str, only: &str) -> Result<(), Fail> {
    loop {
        let readings = readings(&list.file, kit, only)?;
        match core::apply_readings(list, &readings, only) { Err(error) if error.kind == Kind::SyncChanged => continue, other => return other }
    }
}
