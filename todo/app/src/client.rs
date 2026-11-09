//! Talks to the to-do web server: finds it through the session file, starts `todo.mjs serve`
//! when none runs, follows `/events`, and posts the same requests as the web page.
use serde::Deserialize;
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Clone, Deserialize)]
pub struct Session {
    pub port: u16,
    pub token: String,
}

impl Session {
    pub fn origin(&self) -> String { format!("http://127.0.0.1:{}", self.port) }
}

#[derive(Clone, Default, Deserialize)]
pub struct Turn {
    pub actor: String,
    pub kind: String,
    #[serde(default)]
    pub gate: String,
}

#[derive(Clone, Default, Deserialize)]
pub struct Link {
    pub label: String,
    pub url: String,
}

#[derive(Clone, Default, Deserialize)]
pub struct Sdlc {
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub action: String,
}

#[derive(Clone, Default, Deserialize)]
pub struct Item {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub done: bool,
    #[serde(default)]
    pub project: Option<String>,
    #[serde(default)]
    pub link: Option<Link>,
    #[serde(default)]
    pub waiting: String,
    #[serde(default)]
    pub others: String,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub sdlc: Option<Sdlc>,
    #[serde(default)]
    pub brief: String,
    #[serde(default)]
    pub repos: Vec<String>,
    #[serde(default)]
    pub choices: Vec<String>,
    #[serde(default)]
    pub pick: Option<usize>,
    #[serde(default)]
    pub suggest: String,
    #[serde(default)]
    pub run: String,
    /// Kept at the top of every tab (a setting switched with its choices); never counted as needing you.
    #[serde(default)]
    pub pin: bool,
    pub version: String,
    pub turn: Turn,
}

#[derive(Clone, Default, Deserialize)]
pub struct Model {
    pub items: Vec<Item>,
    #[serde(default)]
    pub lang: String,
}

#[derive(Clone, Deserialize)]
pub struct Artifact {
    #[serde(default)]
    pub gate: String,
    #[serde(default)]
    pub file: String,
    #[serde(default)]
    pub markdown: String,
    pub sha: String,
}

pub struct Launcher {
    pub session_file: PathBuf,
    pub kit: PathBuf,
    pub node: String,
    pub lang: String,
}

fn agent(read_timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(2)).timeout_read(read_timeout).build()
}

pub fn read_session(file: &PathBuf) -> Option<Session> {
    let text = std::fs::read_to_string(file).ok()?;
    let session: Session = serde_json::from_str(&text).ok()?;
    (session.token.len() == 32).then_some(session)
}

pub fn live(file: &PathBuf) -> Option<Session> {
    let session = read_session(file)?;
    let response = agent(Duration::from_secs(2))
        .get(&format!("{}/api/live", session.origin()))
        .set("X-Todo-Token", &session.token)
        .call()
        .ok()?;
    (response.status() == 200).then_some(session)
}

impl Launcher {
    /// Starts `todo.mjs serve` and waits until its session answers.
    pub fn serve(&self) -> Result<(Child, Session), String> {
        let script = self.kit.join("todo").join("todo.mjs");
        let mut command = Command::new(&self.node);
        command.arg(&script).arg("serve").arg("--lang").arg(&self.lang)
            .env("SDLC_TODO_SESSION", &self.session_file)
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let mut child = command.spawn().map_err(|e| format!("{} {}: {e}", self.node, script.display()))?;
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if let Some(session) = live(&self.session_file) { return Ok((child, session)); }
            if let Ok(Some(status)) = child.try_wait() { return Err(format!("todo.mjs serve exited: {status}")); }
            std::thread::sleep(Duration::from_millis(250));
        }
        let _ = child.kill();
        Err("todo.mjs serve did not answer in 20 seconds".into())
    }
}

/// Reads `/events` until the stream ends; each `data:` frame is the whole list.
pub fn follow(session: &Session, mut on_model: impl FnMut(Model)) -> Result<(), String> {
    // The server sends a keepalive every 15 seconds, so 40 seconds of silence means it is gone.
    let response = agent(Duration::from_secs(40))
        .get(&format!("{}/events?t={}", session.origin(), session.token))
        .call()
        .map_err(|e| e.to_string())?;
    let mut data = String::new();
    let mut event = String::new();
    for line in BufReader::new(response.into_reader()).lines() {
        let line = line.map_err(|e| e.to_string())?;
        if line.is_empty() {
            if event.is_empty() && !data.is_empty() {
                if let Ok(model) = serde_json::from_str::<Model>(&data) { on_model(model); }
            }
            data.clear();
            event.clear();
        } else if let Some(rest) = line.strip_prefix("data: ") {
            data.push_str(rest);
        } else if let Some(rest) = line.strip_prefix("event: ") {
            event = rest.to_string();
        }
    }
    Err("the event stream ended".into())
}

fn error_text(error: ureq::Error) -> String {
    match error {
        ureq::Error::Status(code, response) => {
            let text = response.into_string().unwrap_or_default();
            serde_json::from_str::<Value>(&text).ok()
                .and_then(|v| v.get("error").and_then(Value::as_str).map(str::to_string))
                .unwrap_or_else(|| if text.trim().is_empty() { format!("HTTP {code}") } else { text.trim().to_string() })
        }
        other => other.to_string(),
    }
}

pub fn post(session: &Session, path: &str, body: Value) -> Result<Value, String> {
    let response = agent(Duration::from_secs(60))
        .post(&format!("{}{path}", session.origin()))
        .set("X-Todo-Token", &session.token)
        .set("Origin", &session.origin())
        .set("Content-Type", "application/json")
        .send_string(&body.to_string())
        .map_err(error_text)?;
    let text = response.into_string().map_err(|e| e.to_string())?;
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

pub fn artifact(session: &Session, id: &str) -> Result<Artifact, String> {
    let response = agent(Duration::from_secs(30))
        .get(&format!("{}/api/artifact", session.origin()))
        .query("id", id)
        .set("X-Todo-Token", &session.token)
        .call()
        .map_err(error_text)?;
    let text = response.into_string().map_err(|e| e.to_string())?;
    serde_json::from_str(&text).map_err(|e| e.to_string())
}
