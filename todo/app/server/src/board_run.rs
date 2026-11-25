//! The command a person runs from the board: recorded in todo.md before it starts and when it ends, so every server
//! and tab sees it, and never started twice.
use super::core::{self, Event, Exec, Fail, Item, Model};
use super::json::{object, Json, Text};
use super::{js, locked, run, Server};
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

type Write = Box<dyn FnMut(&mut Model) -> Result<(), Fail> + Send>;

/// The runs of this process, not of one server: the app may replace its server while a command still runs.
static RUNNING: Mutex<Option<HashSet<String>>> = Mutex::new(None);
/// Results that could not be written yet (run, list, write); until then their run still counts as running.
static PENDING: Mutex<Vec<(String, String, Write)>> = Mutex::new(Vec::new());
static HAS_PENDING: AtomicBool = AtomicBool::new(false);
fn is_running(run: &str) -> bool { locked(&RUNNING).as_ref().is_some_and(|r| r.contains(run)) }
fn set_running(run: &str, on: bool) {
    let mut running = locked(&RUNNING);
    let running = running.get_or_insert_with(HashSet::new);
    if on { running.insert(run.into()); } else { running.remove(run); }
}

struct Started { run: String, pid: u64, server: String, at: Option<i64> }

fn hex_run(text: &str) -> Option<(&str, &str)> {
    let end = text.bytes().position(|b| !(b.is_ascii_digit() || (b'a'..=b'f').contains(&b))).unwrap_or(text.len());
    (end > 0).then(|| text.split_at(end))
}
/// `exec started run=<id> pid=<pid>[ server=<nonce>] `
fn started(event: &Event) -> Option<Started> {
    if event.who != "human" { return None; }
    let (run, rest) = hex_run(event.what.strip_prefix("exec started run=")?)?;
    let rest = rest.strip_prefix(" pid=")?;
    let end = rest.bytes().position(|b| !b.is_ascii_digit()).unwrap_or(rest.len());
    let (pid, rest) = rest.split_at(end);
    let rest = rest.strip_prefix(' ')?;
    if pid.is_empty() { return None; }
    let server = rest.strip_prefix("server=").and_then(hex_run).filter(|(_, after)| after.starts_with(' ')).map_or("", |(s, _)| s);
    Some(Started { run: run.into(), pid: pid.parse().unwrap_or(u64::MAX), server: server.into(), at: js::parse_stamp(&event.at) })
}
fn unfinished(item: &Item) -> Vec<Started> {
    let finished = |run: &str| { let head = format!("exec finished run={run} "); item.events.iter().any(|e| e.who == "human" && e.what.starts_with(&head)) };
    item.events.iter().filter_map(started).filter(|s| !finished(&s.run)).collect()
}
/// Where the event that started `run` is.
fn start_of(item: &Item, run: &str) -> Option<usize> {
    let head = format!("exec started run={run} ");
    item.events.iter().position(|e| e.who == "human" && e.what.starts_with(&head))
}
fn human(what: String) -> Event { Event { at: js::stamp(), who: "human".into(), what } }

/// The log is a record, never a gate: one that cannot be written must not skip the reply.
fn log(entry: Json) {
    use std::io::Write;
    #[cfg(test)]
    let file = { let _ = js::home(); js::join(&std::env::temp_dir().to_string_lossy(), &[&format!("sdlc-todo-runs-{}.log", std::process::id())]) };
    #[cfg(not(test))]
    let file = js::join(&js::home(), &[".sdlc", "todo-runs.log"]);
    let written = (|| -> std::io::Result<()> {
        std::fs::create_dir_all(js::dirname(&file))?;
        let mut options = std::fs::OpenOptions::new();
        options.append(true).create(true);
        #[cfg(unix)]
        { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
        let mut out = options.open(&file)?;
        #[cfg(unix)]
        { use std::os::unix::fs::PermissionsExt; out.set_permissions(std::fs::Permissions::from_mode(0o600))?; }
        out.write_all(format!("{}\n", entry.stringify()).as_bytes())
    })();
    if let Err(error) = written { eprintln!("to-do exec log not written: {error}"); }
}

const LOCALES: [(&str, &str); 2] = [("en", include_str!("../../../locales/en.mjs")), ("ko", include_str!("../../../locales/ko.mjs"))];
/// A message of todo/locales with its `{name}` values.
fn message(lang: &str, key: &str, values: &[(&str, &str)]) -> String {
    let source = LOCALES.iter().find(|(l, _)| *l == lang).map_or("", |(_, text)| text);
    let text = source.lines().find_map(|line| line.trim().strip_prefix('\'')?.strip_prefix(key)?.strip_prefix("': '")?.trim_end().strip_suffix(',')?.strip_suffix('\''));
    super::fill(&text.unwrap_or(key).replace("\\'", "'"), values)
}
fn strings(list: &[Text]) -> Json { Json::Arr(list.iter().cloned().map(Json::Str).collect()) }
fn number(code: Option<i32>) -> Json { code.map_or(Json::Null, |c| Json::Num(c as f64)) }
fn or_null(text: &str) -> Json { if text.is_empty() { Json::Null } else { Json::str(text) } }

impl Server {
    /// This process knows its own runs; another server's counts while its pid lives and it is not too old: no run
    /// outlives its timeout, the KILL that follows, the pipe grace and a minute of slack.
    fn live(&self, run: &Started) -> bool {
        if run.server == self.run_server || run.pid == u64::from(self.options.pid) { return is_running(&run.run); }
        let longest = (self.options.run_timeout + self.options.kill_after + 2000 + 60_000) as i64;
        js::alive(run.pid) && !run.at.is_some_and(|at| js::now_ms() - at > longest)
    }
    /// A run whose server stopped keeps its command for the human.
    fn mark_interrupted(&self, item: &mut Item) {
        for run in unfinished(item) {
            if self.live(&run) { continue; }
            item.events.push(human(format!("exec finished run={} — {}", run.run, message(&self.options.lang, "run.interrupted", &[]))));
            log(object(vec![("at", Json::str(&js::iso(js::now_ms()))), ("id", Json::str(&item.id)), ("run", Json::str(&run.run)), ("event", Json::str("interrupted"))]));
        }
    }
    pub fn mark_dead_runs(&self) -> Result<(), Fail> {
        let file = &self.options.file;
        if !core::load(file)?.items.iter().any(|item| unfinished(item).iter().any(|run| !self.live(run))) { return Ok(()); }
        core::mutate(file, &mut |model| { for item in &mut model.items { self.mark_interrupted(item); } Ok(()) })
    }
    /// Writes results that met a busy lock; called on each request and keepalive tick.
    pub fn flush_finishes(&self) {
        if !HAS_PENDING.load(Ordering::SeqCst) { return; }
        let mut pending = locked(&PENDING);
        while let Some((run, file, write)) = pending.first_mut() {
            if let Err(error) = core::mutate(file, write) { eprintln!("to-do exec result still not written (run {run}): {}", error.message); return; }
            set_running(run, false);
            drop(pending.remove(0));
        }
        HAS_PENDING.store(false, Ordering::SeqCst);
    }
    fn write_finish(&self, run: &str, mut write: Write) {
        let deadline = Instant::now() + Duration::from_millis(self.options.finish_retry);
        let mut wait = 250;
        loop {
            let error = match core::mutate(&self.options.file, &mut write) { Ok(()) => return set_running(run, false), Err(error) => error };
            if Instant::now() + Duration::from_millis(wait) > deadline {
                eprintln!("to-do exec result not written yet (run {run}): {}", error.message);
                let mut pending = locked(&PENDING);
                pending.push((run.into(), self.options.file.clone(), write));
                HAS_PENDING.store(true, Ordering::SeqCst);
                return;
            }
            std::thread::sleep(Duration::from_millis(wait));
            wait = (wait * 2).min(8000);
        }
    }

    /// Runs the item's command as the person saw it: the shown version and program, under the list's lock.
    pub fn run_item(&self, id: Option<&str>, version: Option<&str>, shown: Option<&str>) -> Result<Json, Fail> {
        let options = &self.options;
        let Some(id) = id.filter(|id| core::load(&options.file).is_ok_and(|m| m.by_id(id).is_some())) else { return Fail::at(404, "item not found") };
        if !options.can_exec { return Fail::at(409, "Running a command from the board is not supported on Windows yet; run it yourself and reply."); }
        let Some(shown) = shown else { return Fail::at(400, "invalid path") };
        let run_id = js::hex(&js::random::<4>().map_err(Fail::new)?);
        let path = self.command_path().to_string();
        let (command, snapshot) = core::update(&options.file, Some(id), version, &mut |model, at| {
            let item = &mut model.items[at];
            let Some(command) = item.exec.clone().filter(|_| !item.done) else { return Fail::at(409, "item has no command to run") };
            let cwd = command.cwd.lossy();
            if !std::path::Path::new(&cwd).is_dir() { return Fail::at(400, format!("invalid exec JSON: cwd is not a directory: {cwd}")); }
            if unfinished(item).iter().any(|run| self.live(run)) { return Fail::at(409, "this command is already running"); }
            self.mark_interrupted(item);
            let name = command.argv[0].lossy();
            let program = run::resolve_command(&name, &path);
            if program.is_empty() { return Fail::at(409, format!("command not found: {name}")); }
            if program != shown { return Fail::at(409, "The command now resolves to a different program. Reload and try again."); }
            item.events.push(human(format!("exec started run={run_id} pid={} server={} — {}", options.pid, self.run_server, command.show())));
            set_running(&run_id, true);
            Ok((command, item.clone()))
        // A start that was saved but reported an error runs nothing: the next attempt marks it interrupted.
        }).inspect_err(|_| set_running(&run_id, false))?;
        let (at, started_at) = (js::iso(js::now_ms()), Instant::now());
        let head = || vec![("at", Json::str(&at)), ("id", Json::str(id)), ("run", Json::str(&run_id))];
        let mut entry = head();
        entry.extend([("event", Json::str("start")), ("argv", strings(&command.argv)), ("cwd", Json::Str(command.cwd.clone())), ("path", Json::str(shown))]);
        log(object(entry));
        let argv: Vec<String> = command.argv.iter().map(Text::lossy).collect();
        let result = run::run_argv(run::Job { program: shown, argv: &argv, cwd: &command.cwd.lossy(), path: &path, timeout: options.run_timeout, kill_after: options.kill_after });
        let mut entry = head();
        entry.extend([("argv", strings(&command.argv)), ("cwd", Json::Str(command.cwd.clone())), ("exitCode", number(result.exit_code)), ("ms", Json::Num(started_at.elapsed().as_millis() as f64))]);
        if !result.signal.is_empty() { entry.push(("signal", Json::str(&result.signal))); }
        if !result.error.is_empty() { entry.push(("error", Json::str(&result.error))); }
        if result.timed_out { entry.push(("timedOut", Json::Bool(true))); }
        log(object(entry));
        let words = self.words(&command, &result);
        let record = object(vec![("argv", strings(&command.argv)), ("cwd", Json::Str(command.cwd.clone())), ("resolved", Json::str(shown)), ("exitCode", number(result.exit_code)),
            ("timedOut", Json::Bool(result.timed_out)), ("signal", or_null(&result.signal)), ("at", Json::Null), ("run", Json::str(&run_id))]);
        let (run, code) = (run_id.clone(), result.exit_code);
        // The result goes to the item that started it; only fields still as they were at the start are cleared.
        self.write_finish(&run_id, Box::new(move |model| {
            let Some((item, from)) = model.items.iter_mut().find_map(|i| start_of(i, &run).map(|from| (i, from))) else { return Ok(()) };
            item.events.push(human(format!("exec finished run={run} — {words}")));
            let mut record = record.clone();
            if let Json::Obj(fields) = &mut record { fields[6].1 = Json::str(&js::iso(js::now_ms())); }
            item.exec_result = Some(record);
            // A failure keeps the wait and the command, so the human can retry or answer by hand.
            if item.done || code != Some(0) { return Ok(()); }
            if item.exec == snapshot.exec { item.exec = None; }
            if item.run == snapshot.run { item.run.clear(); }
            let asked = item.events[from + 1..].iter().any(|e| (e.who == "agent" && (e.what.starts_with("waiting — ") || e.what.starts_with("waiting on others — ")))
                || (e.who == "sdlc" && e.what.starts_with("NEEDS-HUMAN — ")));
            if asked || item.waiting != snapshot.waiting || item.others != snapshot.others { return Ok(()); }
            if item.suggest == snapshot.suggest { item.suggest.clear(); }
            item.waiting.clear();
            item.others.clear();
            item.events.push(human(format!("reply — {words}")));
            Ok(())
        }));
        Ok(object(vec![("exitCode", number(result.exit_code)), ("stdout", Json::str(&result.stdout)), ("stderr", Json::str(&result.stderr)), ("timedOut", Json::Bool(result.timed_out)),
            ("signal", or_null(&result.signal)), ("error", Json::str(&result.error))]))
    }
    /// The reply in the list's language: the command, how it ended and its last line of output.
    fn words(&self, command: &Exec, result: &run::Outcome) -> String {
        let code = result.exit_code.map_or("-".into(), |c| c.to_string());
        let seconds = ((self.options.run_timeout as f64 / 1000.0) + 0.5).floor().to_string();
        let (quoted, cwd) = (command.quoted(), js::shell_word(&command.cwd.lossy()));
        let values = [("command", quoted.as_str()), ("cwd", &cwd), ("code", &code), ("seconds", &seconds), ("signal", &result.signal), ("error", &result.error)];
        let key = if !result.error.is_empty() { "run.reply.spawn" } else if result.timed_out { "run.reply.timeout" } else if result.exit_code.is_none() { "run.reply.signal" } else { "run.reply" };
        let mut words = message(&self.options.lang, key, &values);
        let last = |text: &str| text.split('\n').map(js::trim).rfind(|l| !l.is_empty()).unwrap_or("").to_string();
        let line = match last(&result.stdout) { line if line.is_empty() => last(&result.stderr), line => line };
        let line = js::visible(&line, false).0;
        if !line.is_empty() {
            let shown = if js::units(&line) > 200 { format!("{}…", js::slice(&line, 199)) } else { line };
            words.push_str(&message(&self.options.lang, "run.reply.output", &[("text", &shown)]));
        }
        words
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn a_replacement_server_in_this_process_does_not_start_a_running_command_again() {
        let dir = std::env::temp_dir().join(format!("sdlc-todo-replace-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = |name: &str| dir.join(name).to_string_lossy().into_owned();
        std::fs::write(path("todo.md"), format!("## Open\n\n- [ ] a\n  - exec: {{\"argv\":[\"sh\",\"-c\",\"sleep 1\"],\"cwd\":\"{}\"}}\n", path(""))).unwrap();
        let start = || {
            let mut options = crate::Options::for_kit(&dir, std::path::Path::new(""), "node", "en");
            (options.file, options.feed, options.search_path) = (path("todo.md"), path("feed.json"), Some("/usr/bin:/bin".into()));
            crate::start(options).unwrap().server
        };
        let file = path("todo.md");
        let shown = || { let model = core::load(&file).unwrap(); (model.items[0].id.clone(), core::versions(&model).unwrap()[0].clone()) };
        let (first, sh) = (start(), run::resolve_command("sh", "/usr/bin:/bin"));
        let (id, version) = shown();
        std::thread::scope(|scope| {
            let running = scope.spawn(|| first.run_item(Some(&id), Some(&version), Some(&sh)));
            while !std::fs::read_to_string(&file).unwrap().contains("exec started") { std::thread::sleep(Duration::from_millis(10)); }
            let second = start();
            let (id, version) = shown();
            assert_eq!(second.run_item(Some(&id), Some(&version), Some(&sh)).unwrap_err().message, "this command is already running");
            assert!(running.join().unwrap().is_ok());
        });
        let text = std::fs::read_to_string(&file).unwrap();
        assert_eq!((text.matches("exec started").count(), text.matches("exec finished").count(), text.matches("interrupted").count()), (1, 1, 0), "{text}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn every_message_is_found_in_every_language() {
        for (lang, _) in LOCALES {
            for key in ["run.interrupted", "run.reply", "run.reply.timeout", "run.reply.signal", "run.reply.spawn", "run.reply.output"] { assert_ne!(message(lang, key, &[]), key, "{lang} {key}"); }
        }
        assert_eq!(message("en", "run.reply.output", &[("text", "{text}")]), " · output: \"{text}\"");
    }

    #[test]
    fn a_start_event_names_its_run_process_and_server() {
        let event = |what: &str| Event { at: "2026-11-12 03:04".into(), who: "human".into(), what: what.into() };
        let run = started(&event("exec started run=ab12 pid=77 server=cd34 — true")).unwrap();
        assert_eq!((run.run.as_str(), run.pid, run.server.as_str()), ("ab12", 77, "cd34"));
        assert_eq!(started(&event("exec started run=ab12 pid=77 — true")).unwrap().server, "");
        assert!(started(&event("exec started run=xyz pid=77 — true")).is_none());
    }
}
