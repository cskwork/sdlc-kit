//! Serves a list without any window, until its input ends: for the tests (tests/rust-server.mjs) and headless use.
//! `--render` instead reads todo.md text as JSON strings, one per line, and answers each with what it holds.
use sdlc_todo_server::{self as server, json, json::Json};
use std::io::{BufRead, Read, Write};

fn render() -> Result<(), String> {
    let mut out = std::io::stdout().lock();
    for line in std::io::stdin().lock().lines() {
        let source = json::parse(&line.map_err(|e| e.to_string())?).and_then(|v| v.text()).ok_or("not a JSON string")?;
        let texts = |list: Vec<String>| Json::Arr(list.iter().map(|t| Json::str(t)).collect());
        let answer = match server::core::parse(&source).and_then(|m| Ok((server::core::serialize(&m)?, server::core::versions(&m)?, m))) {
            Ok((text, versions, model)) => json::object(vec![("text", Json::str(&text)), ("versions", texts(versions)),
                ("ids", texts(model.items.iter().map(|i| i.id.clone()).collect())), ("status", texts(model.items.iter().map(|i| format!("{:?}", i.status).to_lowercase()).collect())),
                ("unread", Json::Arr(model.items.iter().map(|i| Json::Num(i.unread as f64)).collect()))]),
            Err(error) => json::object(vec![("error", Json::str(&error.message))]),
        };
        writeln!(out, "{}", answer.stringify()).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let (mut kit, mut session, mut node, mut lang, mut values) = (String::new(), String::new(), "node".to_string(), "en".to_string(), Vec::new());
    let mut rendering = false;
    while let Some(flag) = args.next() {
        if flag == "--render" { rendering = true; continue; }
        let value = args.next().ok_or_else(|| format!("missing value for {flag}"))?;
        match flag.as_str() { "--kit" => kit = value, "--session" => session = value, "--node" => node = value, "--lang" => lang = value, _ => values.push((flag, value)) }
    }
    let mut options = server::Options::for_kit(kit.as_ref(), session.as_ref(), &node, &lang);
    options.lang = lang;
    options.sync_first = true;
    for (flag, value) in values {
        let number = || value.parse::<u64>().map_err(|e| format!("{flag}: {e}"));
        match flag.as_str() {
            "--file" => options.file = value,
            "--feed" => options.feed = value,
            "--status-kit" => options.kit = value,
            "--search-path" => options.search_path = Some(value),
            "--run-timeout" => options.run_timeout = number()?,
            "--kill-after" => options.kill_after = number()?,
            "--finish-retry" => options.finish_retry = number()?,
            "--defer" => options.sync_first = value != "true",
            "--platform" => options.can_exec = value != "win32" && options.can_exec,
            "--pid" => options.pid = number()? as u32,
            _ => return Err(format!("unknown option: {flag}")),
        }
    }
    if rendering { server::configure_helper(&options); return render(); }
    let server = server::start(options)?;
    let _ = std::io::stdin().lock().read_to_end(&mut Vec::new());
    server.close();
    Ok(())
}
