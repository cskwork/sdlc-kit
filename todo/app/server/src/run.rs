//! Child processes: short status commands as Node's execFile runs them, and the command a person runs from the board.
use super::js;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};

/// Node's execFile failure: `stderr` when the command wrote any, else `message`.
pub struct Failed { pub message: String, pub stderr: String }
impl Failed { pub fn text(self) -> String { if self.stderr.is_empty() { self.message } else { self.stderr } } }

/// How Node reports a program that cannot start: these codes arrive as an event that names it, others are thrown.
fn spawn_error(program: &str, code: &str) -> String {
    if said_later(code) { format!("spawn {program} {code}") } else { format!("spawn {code}") }
}
/// The code of a failed spawn. std searches the PATH after a failed chdir and reports ENOENT for any bad cwd.
fn spawn_code(error: &std::io::Error, cwd: Option<&str>) -> String {
    match cwd.map(std::fs::metadata) {
        Some(Err(cwd)) => js::errno(&cwd).0,
        // libuv gives ENOENT for any bad folder on Windows.
        Some(Ok(meta)) if !meta.is_dir() => if cfg!(windows) { "ENOENT" } else { "ENOTDIR" }.into(),
        _ => js::errno(error).0,
    }
}
fn said_later(code: &str) -> bool { matches!(code, "EACCES" | "EAGAIN" | "EMFILE" | "ENFILE" | "ENOENT") }

/// Makes the child lead its own session, as Node's `detached` does. On macOS it also execs `program` directly: libuv
/// refuses a file without `#!` there (ENOEXEC), while std's execvp would hand it to a shell.
#[cfg(unix)]
fn detach(command: &mut Command, program: &str, argv: &[String], path: Option<&str>) {
    use std::os::unix::process::CommandExt;
    #[cfg(target_os = "macos")]
    let direct = {
        let mut env: Vec<(std::ffi::OsString, std::ffi::OsString)> = std::env::vars_os().collect();
        let mut set = |name: &str, value: std::ffi::OsString| { env.retain(|(n, _)| n != name); env.push((name.into(), value)); };
        if let Some(session) = super::session_env() { set("SDLC_TODO_SESSION", session.into_os_string()); }
        if let Some(path) = path { set("PATH", path.into()); }
        direct_exec(program, argv, env)
    };
    #[cfg(not(target_os = "macos"))]
    let _ = (program, argv, path);
    // SAFETY: setsid and execve are async-signal-safe, and everything they read was built before the fork.
    unsafe {
        command.pre_exec(move || {
            libc::setsid();
            #[cfg(target_os = "macos")]
            if let Some(direct) = &direct {
                libc::execve(direct.program.as_ptr(), direct.argv.as_ptr(), direct.env.as_ptr());
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
}
#[cfg(target_os = "macos")]
struct Direct { program: std::ffi::CString, argv: Vec<*const libc::c_char>, env: Vec<*const libc::c_char>, _strings: Vec<std::ffi::CString> }
// SAFETY: the pointers lead into _strings, whose buffers neither move nor change.
#[cfg(target_os = "macos")]
unsafe impl Send for Direct {}
#[cfg(target_os = "macos")]
unsafe impl Sync for Direct {}
/// None (std's way) for a bare name, which needs a PATH search.
#[cfg(target_os = "macos")]
fn direct_exec(program: &str, argv: &[String], env: Vec<(std::ffi::OsString, std::ffi::OsString)>) -> Option<Direct> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStringExt;
    if !js::is_absolute(program) { return None; }
    let arguments = argv.iter().map(|a| CString::new(a.as_str())).collect::<Result<Vec<_>, _>>().ok()?;
    let variables = env.into_iter().filter_map(|(name, value)| { let mut v = name.into_vec(); v.push(b'='); v.extend(value.into_vec()); CString::new(v).ok() }).collect::<Vec<_>>();
    let pointers = |list: &[CString]| list.iter().map(|s| s.as_ptr()).chain([std::ptr::null()]).collect::<Vec<_>>();
    let (argv, env) = (pointers(&arguments), pointers(&variables));
    Some(Direct { program: CString::new(program).ok()?, argv, env, _strings: arguments.into_iter().chain(variables).collect() })
}

const MAX_BUFFER: usize = 1024 * 1024;

/// The program std starts for a bare name on Windows, where std looks in System32 (WSL's bash.exe) before the PATH
/// and Node does not.
pub fn on_path(name: &str) -> String {
    if !cfg!(windows) || name.contains(['/', '\\', ':']) { return name.into(); }
    let path = std::env::var("PATH").unwrap_or_default();
    let found = path.split(';').filter(|dir| !dir.is_empty()).flat_map(|dir| [format!("{dir}\\{name}.exe"), format!("{dir}\\{name}.com")]).find(|file| Path::new(file).is_file());
    found.unwrap_or_else(|| name.into())
}
/// execFile(program, args, { cwd }): stdout on exit 0.
pub fn exec_file(program: &str, args: &[&str], cwd: Option<&str>) -> Result<String, Failed> {
    let start = |e: std::io::Error| Failed { message: spawn_error(program, &spawn_code(&e, cwd)), stderr: String::new() };
    let mut command = Command::new(on_path(program));
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    if let Some(cwd) = cwd { command.current_dir(cwd); }
    super::child_env(&mut command);
    super::no_window(&mut command);
    let mut child = command.spawn().map_err(start)?;
    let (mut out, err) = (child.stdout.take(), child.stderr.take());
    let reader = std::thread::Builder::new().spawn(move || {
        let mut bytes = Vec::new();
        // Read to the end so the command never blocks, keeping what Node would.
        if let Some(mut err) = err { let _ = err.by_ref().take(MAX_BUFFER as u64).read_to_end(&mut bytes); let _ = std::io::copy(&mut err, &mut std::io::sink()); }
        String::from_utf8_lossy(&bytes).into_owned()
    });
    let errors = match reader {
        Ok(reader) => reader,
        Err(error) => { let _ = child.kill(); let _ = child.wait(); return Err(Failed { message: format!("no thread to read {program}: {error}"), stderr: String::new() }); }
    };
    let mut bytes = Vec::new();
    if let Some(out) = out.as_mut() { let _ = out.take(MAX_BUFFER as u64 + 1).read_to_end(&mut bytes); }
    let full = bytes.len() > MAX_BUFFER;
    if full { let _ = child.kill(); }
    drop(out);
    let status = child.wait().map_err(start)?;
    let stderr = errors.join().unwrap_or_default();
    if full { return Err(Failed { message: "stdout maxBuffer length exceeded".into(), stderr }); }
    if status.success() { return Ok(String::from_utf8_lossy(&bytes).into_owned()); }
    let line = std::iter::once(program).chain(args.iter().copied()).collect::<Vec<_>>().join(" ");
    Err(Failed { message: format!("Command failed: {line}\n{stderr}"), stderr })
}

/// A path from Bash as this platform writes it (cygpath on Windows).
pub fn native_path(value: &str) -> Result<String, Failed> {
    if !cfg!(windows) || !value.starts_with('/') || value.starts_with("//") { return Ok(value.into()); }
    let out = exec_file("bash", &["-c", "cygpath -w -- \"$1\"", "sdlc-path", value], None)?;
    let out = out.strip_suffix('\n').map(|o| o.strip_suffix('\r').unwrap_or(o)).unwrap_or(&out);
    Ok(out.into())
}

/// The program `name` starts, '' when none: an absolute path, or the first match on the search path.
pub fn resolve_command(name: &str, search_path: &str) -> String {
    if js::is_absolute(name) { return if executable(name) { name.into() } else { String::new() }; }
    search_path.split(if cfg!(windows) { ';' } else { ':' }).map(|dir| js::join(dir, &[name])).find(|file| executable(file)).unwrap_or_default()
}
fn executable(file: &str) -> bool {
    if !Path::new(file).is_file() { return false; }
    #[cfg(unix)]
    {
        let Ok(name) = std::ffi::CString::new(file) else { return false };
        // SAFETY: a NUL-terminated path.
        unsafe { libc::access(name.as_ptr(), libc::X_OK) == 0 }
    }
    #[cfg(not(unix))]
    true
}
/// The PATH a board command is found on: the login shell's first, then this process's, absolute entries only.
#[cfg(unix)]
pub fn command_search_path() -> String {
    let shell = std::env::var("SHELL").unwrap_or_default();
    let login = if js::is_absolute(&shell) { login_path(&shell).unwrap_or_default() } else { String::new() };
    let mut out: Vec<String> = Vec::new();
    for entry in login.split(':').chain(std::env::var("PATH").unwrap_or_default().split(':')) {
        if js::is_absolute(entry) && !out.iter().any(|o| o == entry) { out.push(entry.into()); }
    }
    out.join(":")
}
#[cfg(unix)]
fn login_path(shell: &str) -> Option<String> {
    let mut command = Command::new(shell);
    command.args(["-lc", "printf %s \"$PATH\""]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    super::child_env(&mut command);
    let mut child = command.spawn().ok()?;
    let mut out = child.stdout.take()?;
    // Until the shell exits and the pipe ends, at most 5 s: a profile may leave a background process holding the pipe,
    // and what was printed counts once the shell itself exited 0.
    let (sent, chunks) = std::sync::mpsc::channel::<Vec<u8>>();
    std::thread::Builder::new().spawn(move || {
        let mut buffer = [0; 4096];
        while let Ok(n) = out.read(&mut buffer) { if n == 0 || sent.send(buffer[..n].to_vec()).is_err() { break; } }
    }).ok()?;
    let until = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let mut text = Vec::new();
    while let Ok(chunk) = chunks.recv_timeout(until.saturating_duration_since(std::time::Instant::now())) { text.extend(chunk); }
    loop {
        if let Some(status) = child.try_wait().ok()? { return status.success().then(|| String::from_utf8_lossy(&text).into_owned()); }
        if std::time::Instant::now() >= until { let _ = child.kill(); let _ = child.wait(); return None; }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

/// Starts a program that outlives this one; 'started' or why not. An error Node throws fails the request.
pub fn launch(argv: &[String], cwd: &str) -> Result<String, super::Fail> {
    let mut command = Command::new(on_path(&argv[0]));
    command.args(&argv[1..]).current_dir(cwd).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    super::child_env(&mut command);
    #[cfg(unix)]
    detach(&mut command, &argv[0], argv, None);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0000_0208); // DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    }
    match command.spawn() {
        Ok(mut child) => { std::thread::spawn(move || { let _ = child.wait(); }); Ok("started".into()) }
        Err(error) => {
            let code = spawn_code(&error, Some(cwd));
            if said_later(&code) { Ok(format!("failed: {code}")) } else { Err(super::Fail::new(spawn_error(&argv[0], &code))) }
        }
    }
}

pub struct Outcome { pub exit_code: Option<i32>, pub signal: String, pub error: String, pub timed_out: bool, pub stdout: String, pub stderr: String }
// Windows runs no board command yet.
#[cfg_attr(not(unix), allow(dead_code))]
pub struct Job<'a> { pub program: &'a str, pub argv: &'a [String], pub cwd: &'a str, pub path: &'a str, pub timeout: u64, pub kill_after: u64 }

#[cfg(not(unix))]
pub fn run_argv(_: Job) -> Outcome {
    Outcome { exit_code: Some(126), signal: String::new(), error: "ENOTSUP".into(), timed_out: false, stdout: String::new(), stderr: "not supported".into() }
}

#[cfg(unix)]
pub use unix::run_argv;

#[cfg(unix)]
mod unix {
    use super::*;
    use std::os::fd::{AsRawFd, OwnedFd};
    use std::os::unix::process::{CommandExt, ExitStatusExt};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Arc, Mutex};
    use std::time::{Duration, Instant};

    const LIMIT: usize = 64 * 1024;
    const GRACE: u64 = 2000;

    /// The last 64 KB of a stream, cut on a UTF-8 character boundary.
    #[derive(Default)]
    struct Tail { bytes: Vec<u8>, cut: bool }
    impl Tail {
        fn push(&mut self, chunk: &[u8]) {
            self.bytes.extend_from_slice(chunk);
            if self.bytes.len() > 2 * LIMIT { self.bytes.drain(..self.bytes.len() - LIMIT); self.cut = true; }
        }
        fn text(&self) -> String {
            let over = self.bytes.len().saturating_sub(LIMIT);
            let (mut bytes, cut) = (&self.bytes[over..], self.cut || over > 0);
            while cut && bytes.first().is_some_and(|b| b & 0xc0 == 0x80) { bytes = &bytes[1..]; }
            String::from_utf8_lossy(bytes).into_owned()
        }
    }

    struct Closed;

    /// Reads a pipe until it ends or `stop` is set: a background process may hold it open for ever.
    fn read(pipe: OwnedFd, tail: Arc<Mutex<Tail>>, stop: Arc<AtomicBool>, done: mpsc::Sender<Closed>) -> std::io::Result<()> {
        std::thread::Builder::new().spawn(move || {
            let mut buffer = vec![0u8; 16 * 1024];
            while !stop.load(Ordering::SeqCst) {
                let mut poll = libc::pollfd { fd: pipe.as_raw_fd(), events: libc::POLLIN, revents: 0 };
                // SAFETY: one valid pollfd; the pipe is open while this thread runs.
                let ready = unsafe { libc::poll(&mut poll, 1, 100) };
                if ready <= 0 { continue; }
                // SAFETY: reads into the buffer, at most its length.
                let n = unsafe { libc::read(pipe.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
                if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted { continue; }
                if n <= 0 { break; }
                tail.lock().unwrap_or_else(|e| e.into_inner()).push(&buffer[..n as usize]);
            }
            let _ = done.send(Closed);
        }).map(|_| ())
    }
    // SAFETY (both): a signal to a process group this server started.
    fn group(pid: i32, signal: i32) { unsafe { libc::kill(-pid, signal); } }
    fn name(signal: i32) -> String {
        let known = [(libc::SIGHUP, "SIGHUP"), (libc::SIGINT, "SIGINT"), (libc::SIGQUIT, "SIGQUIT"), (libc::SIGILL, "SIGILL"), (libc::SIGTRAP, "SIGTRAP"),
            (libc::SIGABRT, "SIGABRT"), (libc::SIGBUS, "SIGBUS"), (libc::SIGFPE, "SIGFPE"), (libc::SIGKILL, "SIGKILL"), (libc::SIGUSR1, "SIGUSR1"),
            (libc::SIGSEGV, "SIGSEGV"), (libc::SIGUSR2, "SIGUSR2"), (libc::SIGPIPE, "SIGPIPE"), (libc::SIGALRM, "SIGALRM"), (libc::SIGTERM, "SIGTERM"),
            (libc::SIGXCPU, "SIGXCPU"), (libc::SIGXFSZ, "SIGXFSZ"), (libc::SIGVTALRM, "SIGVTALRM"), (libc::SIGPROF, "SIGPROF"), (libc::SIGSYS, "SIGSYS")];
        known.into_iter().find(|(n, _)| *n == signal).map_or(format!("SIG{signal}"), |(_, name)| name.into())
    }
    fn not_started(error: &str, message: String) -> Outcome {
        Outcome { exit_code: Some(if error == "ENOENT" { 127 } else { 126 }), signal: String::new(), error: error.into(), timed_out: false, stdout: String::new(), stderr: message }
    }

    /// Runs argv as given: no shell, its own session, TERM then KILL to the whole group at the timeout.
    pub fn run_argv(job: Job) -> Outcome {
        if !Path::new(job.cwd).is_dir() { return not_started("ENOTDIR", format!("cwd is not a directory: {}", job.cwd)); }
        let mut command = Command::new(job.program);
        command.arg0(&job.argv[0]).args(&job.argv[1..]).current_dir(job.cwd).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        crate::child_env(&mut command);
        command.env("PATH", job.path);
        detach(&mut command, job.program, job.argv, Some(job.path));
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => { let code = js::errno(&error).0; return not_started(&code, spawn_error(job.program, &code)); }
        };
        let pid = child.id() as i32;
        let (tell, closed) = mpsc::channel();
        let (out, err, stop) = (Arc::new(Mutex::new(Tail::default())), Arc::new(Mutex::new(Tail::default())), Arc::new(AtomicBool::new(false)));
        let mut open = 0;
        for (pipe, tail) in [(child.stdout.take().map(OwnedFd::from), &out), (child.stderr.take().map(OwnedFd::from), &err)] {
            let Some(pipe) = pipe else { continue };
            open += 1;
            if let Err(error) = read(pipe, tail.clone(), stop.clone(), tell.clone()) {
                // A command nobody reads or times must not run on.
                group(pid, libc::SIGKILL);
                let _ = child.wait();
                stop.store(true, Ordering::SeqCst);
                return not_started("EAGAIN", error.to_string());
            }
        }
        let timeout = Instant::now() + Duration::from_millis(job.timeout);
        let (mut timed_out, mut exited, mut grace) = (false, None, None::<Instant>);
        loop {
            // `tell` stays open here, so this waits 20 ms unless a pipe closes.
            if closed.recv_timeout(Duration::from_millis(20)).is_ok() { open -= 1; }
            if exited.is_none() {
                match child.try_wait() {
                    Ok(Some(status)) => { exited = Some(status); grace = Some(Instant::now() + Duration::from_millis(GRACE)); }
                    Ok(None) => {}
                    Err(_) => break,
                }
            }
            if exited.is_some() && open == 0 || grace.is_some_and(|g| Instant::now() >= g) { break; }
            if !timed_out && Instant::now() >= timeout {
                timed_out = true;
                group(pid, libc::SIGTERM);
                // The KILL also reaches grandchildren after the leader exits.
                let after = Duration::from_millis(job.kill_after);
                let later = std::thread::Builder::new().spawn(move || { std::thread::sleep(after); group(pid, libc::SIGKILL); });
                if later.is_err() { group(pid, libc::SIGKILL); }
            }
        }
        drop(tell);
        stop.store(true, Ordering::SeqCst);
        let text = |tail: &Mutex<Tail>| tail.lock().unwrap_or_else(|e| e.into_inner()).text();
        Outcome { exit_code: exited.and_then(|s| s.code()), signal: exited.and_then(|s| s.signal()).map(name).unwrap_or_default(), error: String::new(),
            timed_out, stdout: text(&out), stderr: text(&err) }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn go(dir: &str, argv: &[&str], timeout: u64) -> Outcome {
            let argv: Vec<String> = argv.iter().map(|a| a.to_string()).collect();
            let found = resolve_command(&argv[0], "/usr/bin:/bin");
            let program = if found.is_empty() { argv[0].clone() } else { found };
            run_argv(Job { program: &program, argv: &argv, cwd: dir, path: "/usr/bin:/bin", timeout, kill_after: 500 })
        }

        #[test]
        fn kills_the_group_bounds_output_and_names_start_errors() {
            let dir = std::env::temp_dir().join(format!("sdlc-todo-run-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let dir = dir.to_string_lossy().into_owned();
            let killed = go(&dir, &["sh", "-c", "sh -c 'trap \"\" TERM; echo $$ > pid; while :; do sleep 0.2; done' & wait"], 800);
            assert!(killed.timed_out);
            let pid: u64 = std::fs::read_to_string(format!("{dir}/pid")).unwrap().trim().parse().unwrap();
            let end = Instant::now() + Duration::from_secs(5);
            while js::alive(pid) { assert!(Instant::now() < end, "the grandchild is still alive"); std::thread::sleep(Duration::from_millis(50)); }
            let started = Instant::now();
            let quick = go(&dir, &["sh", "-c", "(sleep 20 &); echo quick"], 30_000);
            assert_eq!((quick.exit_code, quick.stdout.as_str()), (Some(0), "quick\n"));
            assert!(started.elapsed() < Duration::from_secs(10));
            let big = go(&dir, &["sh", "-c", "i=0; while [ $i -lt 40 ]; do printf '가나다라%.0s' $(seq 1 2000); i=$((i+1)); done; echo; echo end"], 60_000);
            assert_eq!(big.exit_code, Some(0));
            assert!(big.stdout.len() <= LIMIT && !big.stdout.contains('\u{fffd}') && big.stdout.ends_with("\nend\n"));
            assert_eq!((go(&dir, &["no-such-command-xyz"], 1000).exit_code, go(&dir, &["no-such-command-xyz"], 1000).error), (Some(127), "ENOENT".into()));
            std::fs::write(format!("{dir}/plain"), "not a program").unwrap();
            let plain = go(&dir, &[&format!("{dir}/plain")], 1000);
            assert_eq!((plain.exit_code, plain.error.as_str()), (Some(126), "EACCES"));
            #[cfg(target_os = "macos")]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(format!("{dir}/plain"), std::fs::Permissions::from_mode(0o755)).unwrap();
                let script = go(&dir, &[&format!("{dir}/plain")], 1000);
                assert_eq!((script.exit_code, script.error.as_str(), script.stderr.as_str()), (Some(126), "ENOEXEC", "spawn ENOEXEC"));
                let named = go(&dir, &["sh", "-c", "echo $0 $PATH"], 5000);
                assert_eq!(named.stdout, "sh /usr/bin:/bin\n");
            }
            let gone = go(&format!("{dir}/gone"), &["sh", "-c", "true"], 1000);
            assert_eq!((gone.exit_code, gone.error.as_str()), (Some(126), "ENOTDIR"));
            let signal = go(&dir, &["sh", "-c", "kill -9 $$"], 5000);
            assert_eq!((signal.exit_code, signal.signal.as_str()), (None, "SIGKILL"));
            std::fs::remove_dir_all(dir).unwrap();
        }
    }
}
