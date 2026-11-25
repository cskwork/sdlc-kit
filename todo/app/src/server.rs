//! The to-do server this app shows: find the running one, start one, stop the one it started, follow its events.
//! The rest of the app knows the server only through `Launcher` and `Server`, so another server can take its place
//! here.
use crate::model::Model;
use serde::Deserialize;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Clone, Deserialize, PartialEq, Eq)]
pub struct Session {
    pub port: u16,
    pub token: String,
}

impl Session {
    pub fn origin(&self) -> String { format!("http://127.0.0.1:{}", self.port) }

    /// The board's address: the web page with the token in its fragment, as `urlOf` in todo/web.mjs builds it, plus
    /// `app=1` (singleWindow in todo/page/app.js).
    pub fn board_url(&self) -> String { format!("{}/#t={}&app=1", self.origin(), self.token) }

    /// `text` without the token: errors name the address they failed on, and the token is never shown or logged.
    fn redact(&self, text: &str) -> String { text.replace(&self.token, "…") }
}

/// Where the server is found and how one is started.
pub struct Launcher {
    pub session_file: PathBuf,
    pub kit: PathBuf,
    pub node: String,
    pub lang: String,
}

/// A server this app started.
pub struct Server { child: Child }

impl Server {
    /// Reaps it when it has exited by itself: its successor checks the file-lock owner's process id.
    pub fn reap(&mut self) { let _ = self.child.try_wait(); }
    pub fn stop(&mut self) { if self.child.kill().is_ok() { let _ = self.child.wait(); } }
}

impl Launcher {
    /// The session of the server that answers now, if any.
    pub fn find_live(&self) -> Option<Session> { live(&self.session_file) }

    /// Starts `todo.mjs serve` and waits until its session answers.
    pub fn start(&self) -> Result<(Server, Session), String> {
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
        let mut server = Server { child: command.spawn().map_err(|e| format!("{} {}: {e}", self.node, script.display()))? };
        // The server syncs the whole board before listening. On a busy board this can take over a minute, so give
        // startup longer than a regular HTTP request.
        let startup_timeout = Duration::from_secs(90);
        let deadline = Instant::now() + startup_timeout;
        while Instant::now() < deadline {
            if let Some(session) = self.find_live() { return Ok((server, session)); }
            if let Ok(Some(status)) = server.child.try_wait() { return Err(format!("todo.mjs serve exited: {status}")); }
            std::thread::sleep(Duration::from_millis(250));
        }
        server.stop();
        Err(format!("todo.mjs serve did not answer in {} seconds", startup_timeout.as_secs()))
    }
}

fn agent(read_timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(2)).timeout_read(read_timeout).build()
}

fn read_session(file: &Path) -> Option<Session> {
    let session: Session = serde_json::from_str(&std::fs::read_to_string(file).ok()?).ok()?;
    // Hexadecimal, as the server writes it: it goes into an address, where nothing else may come along.
    (session.token.len() == 32 && session.token.bytes().all(|b| b.is_ascii_hexdigit())).then_some(session)
}

fn live(file: &Path) -> Option<Session> {
    let session = read_session(file)?;
    let response = agent(Duration::from_secs(2)).get(&format!("{}/api/live", session.origin()))
        .set("X-Todo-Token", &session.token).call().ok()?;
    (response.status() == 200).then_some(session)
}

/// Reads `/events` until the stream ends; each `data:` frame is the whole list.
pub fn follow(session: &Session, mut on_model: impl FnMut(Model)) -> Result<(), String> {
    // The server sends a keepalive every 15 seconds, so 40 seconds of silence means it is gone.
    let response = agent(Duration::from_secs(40))
        .get(&format!("{}/events?t={}", session.origin(), session.token))
        .call().map_err(|e| session.redact(&e.to_string()))?;
    let (mut data, mut event) = (String::new(), String::new());
    for line in BufReader::new(response.into_reader()).lines() {
        let line = line.map_err(|e| session.redact(&e.to_string()))?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    const TOKEN: &str = "0123456789abcdef0123456789abcdef";

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sdlc-todo-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A server that answers one request with `response` and returns the request.
    fn once(response: &'static str) -> (u16, std::thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        (port, std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0; 4096];
            let n = stream.read(&mut buffer).unwrap();
            stream.write_all(response.as_bytes()).unwrap();
            String::from_utf8_lossy(&buffer[..n]).to_string()
        }))
    }

    #[test]
    fn a_session_counts_only_while_its_server_answers_and_its_token_is_well_formed() {
        let dir = scratch("session");
        let file = dir.join("todo-web.json");
        assert!(live(&file).is_none(), "no file");
        std::fs::write(&file, "{ broken").unwrap();
        assert!(live(&file).is_none());
        for token in ["short", "0123456789abcdef0123456789abcde&", "0123456789abcdef0123456789abcde\""] {
            std::fs::write(&file, serde_json::json!({ "port": 1, "token": token }).to_string()).unwrap();
            assert!(read_session(&file).is_none(), "{token}");
        }
        let (port, served) = once("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
        std::fs::write(&file, serde_json::json!({ "port": port, "token": TOKEN, "pid": 1 }).to_string()).unwrap();
        assert!(live(&file).is_some_and(|session| session.port == port));
        let request = served.join().unwrap();
        assert!(request.starts_with("GET /api/live ") && request.to_lowercase().contains(&format!("x-todo-token: {TOKEN}")));
        // Nothing listens there any more, or it refuses the token: not live.
        assert!(live(&file).is_none());
        let (port, _) = once("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        std::fs::write(&file, serde_json::json!({ "port": port, "token": TOKEN }).to_string()).unwrap();
        assert!(live(&file).is_none());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn events_bring_the_list_and_error_frames_do_not() {
        let (port, _) = once("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n: keepalive\n\nevent: error\ndata: {\"items\":[]}\n\ndata: {\"lang\":\"ko\",\"items\":[]}\n\n");
        let mut langs = Vec::new();
        let ended = follow(&Session { port, token: TOKEN.into() }, |model| langs.push(model.lang));
        assert_eq!(langs, ["ko"]);
        assert!(ended.is_err());
    }

    #[test]
    fn a_failed_connection_never_shows_the_token() {
        let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let error = follow(&Session { port, token: TOKEN.into() }, |_| {}).unwrap_err();
        assert!(!error.contains(TOKEN), "{error}");
        assert!(error.contains(&port.to_string()), "the address stays: {error}");
    }

    #[test]
    fn a_server_that_cannot_start_or_exits_is_reported() {
        let dir = scratch("launcher");
        let launcher = |node: &str| Launcher { session_file: dir.join("none.json"), kit: dir.clone(), node: node.into(), lang: "en".into() };
        assert!(launcher("/nonexistent/node").start().is_err_and(|e| e.contains("/nonexistent/node")));
        // `cargo --version serve …` exits at once, on every system that builds this.
        let error = launcher(env!("CARGO")).start().err().unwrap();
        assert!(error.contains("exited"), "{error}");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
