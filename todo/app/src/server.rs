//! The to-do server this app shows: the one that already answers, else one it runs itself (the sdlc-todo-server
//! crate). The rest of the app knows the server only through `Launcher`, `Server` and HTTP.
use crate::model::Model;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::time::Duration;

#[derive(Clone, PartialEq, Eq)]
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

/// Where the server is found and what one started here serves.
pub struct Launcher {
    pub session_file: PathBuf,
    pub kit: PathBuf,
    pub node: String,
    pub lang: String,
}

/// A server this app runs. `close` before the process ends: nothing does it on Windows otherwise.
pub struct Server(sdlc_todo_server::Handle);

impl Server { pub fn close(&self) { self.0.close(); } }

impl Launcher {
    /// The server that answers for this list, or one started here.
    pub fn find_or_start(&self) -> Result<(Session, Option<Server>), String> {
        let options = sdlc_todo_server::Options::for_kit(&self.kit, &self.session_file, &self.node, &self.lang);
        let (session, handle) = sdlc_todo_server::find_or_start(options)?;
        Ok((Session { port: session.port, token: session.token }, handle.map(Server)))
    }
}

fn agent(read_timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(2)).timeout_read(read_timeout).build()
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

    /// The app's server end to end: started for a list, found again by its session file, followed, closed.
    #[test]
    fn a_server_is_started_once_found_again_and_gone_after_close() {
        let dir = std::env::temp_dir().join(format!("sdlc-todo-own-server-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("todo.md");
        std::fs::write(&file, "# To-do\n\n## Open\n\n- [ ] One thing\n  - waiting: which?\n\n## Done\n").unwrap();
        let launcher = Launcher { session_file: dir.join("todo-web.json"), kit: PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."), node: "node".into(), lang: "ko".into() };
        // Options::for_kit reads the list's path from the environment; no other test does.
        std::env::set_var("SDLC_TODO", &file);
        std::env::set_var("SDLC_TODO_FEED", dir.join("feed.json"));
        let (session, server) = launcher.find_or_start().unwrap();
        let server = server.expect("none was running");
        let (again, second) = launcher.find_or_start().unwrap();
        assert!(again == session && second.is_none(), "the running one is used");
        let seen = std::sync::Mutex::new(None);
        std::thread::scope(|scope| {
            scope.spawn(|| follow(&session, |model| *seen.lock().unwrap() = Some((model.lang.clone(), model.waiting()))));
            for _ in 0..200 {
                if seen.lock().unwrap().is_some() { break; }
                std::thread::sleep(Duration::from_millis(25));
            }
            server.close();
        });
        assert_eq!(*seen.lock().unwrap(), Some(("ko".to_string(), 1)));
        assert!(!launcher.session_file.exists(), "its session file goes with it");
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
}
