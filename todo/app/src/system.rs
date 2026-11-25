//! What the shell asks of the operating system: opening an address, and a terminal with a command typed.
use crate::links::{classify, system_may_open, Target};
use std::path::PathBuf;
use std::process::{Command, Stdio};

/// Opens a web address or a mail link with the system's handler; anything else is refused, since the handler would
/// launch it.
pub fn open_url(url: &str) {
    if classify(url) == Target::Other && !system_may_open(url) { return; }
    let (program, args): (&str, Vec<&str>) = if cfg!(target_os = "macos") { ("open", vec![url]) }
        else if cfg!(windows) { ("rundll32.exe", vec!["url.dll,FileProtocolHandler", url]) }
        else { ("xdg-open", vec![url]) };
    // Waited for on a thread of its own, so the finished handler is reaped instead of left as a zombie.
    if let Ok(mut child) = Command::new(program).args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() {
        std::thread::spawn(move || { let _ = child.wait(); });
    }
}

/// Google Chrome in /Applications or ~/Applications.
#[cfg(target_os = "macos")]
pub fn chrome_installed() -> bool {
    let home = std::env::var_os("HOME").map(|home| PathBuf::from(home).join("Applications"));
    std::iter::once(PathBuf::from("/Applications")).chain(home).any(|dir| dir.join("Google Chrome.app").is_dir())
}

/// Whether a terminal can open with a command typed at its prompt: macOS with zsh.
pub fn has_terminal() -> bool { cfg!(target_os = "macos") && std::path::Path::new("/bin/zsh").exists() }

fn quote(text: &str) -> String { format!("'{}'", text.replace('\'', "'\\''")) }

/// The throwaway .zshrc: the person's own, then the command put in the line editor (`print -z`).
fn typed_rc(dir: &str, command: &str) -> String {
    format!("ZDOTDIR=$HOME\n[[ -f $HOME/.zshrc ]] && source $HOME/.zshrc\ncommand rm -rf -- {}\nprint -rz -- {}\n", quote(dir), quote(command))
}

/// Opens Terminal with `command` typed at the prompt but not run, so the human reads it and presses Enter.
/// A throwaway ZDOTDIR loads the human's ~/.zshrc, then `print -z` puts the command in the line editor; nothing is
/// typed into the terminal, so nothing can run early. Returns false where that is not possible.
pub fn open_terminal(command: &str) -> bool {
    if !has_terminal() || command.chars().any(char::is_control) { return false; }
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or_default();
    let dir: PathBuf = std::env::temp_dir().join(format!("sdlc-run-{}-{stamp}", std::process::id()));
    let dir_text = dir.to_string_lossy().to_string();
    // Terminal's session restore would write under the throwaway directory; this shell needs none.
    let launcher = format!("#!/bin/zsh\nSHELL_SESSIONS_DISABLE=1 ZDOTDIR={} exec /bin/zsh -i\n", quote(&dir_text));
    let script = dir.join("run.command");
    let written = std::fs::create_dir_all(&dir).is_ok() && std::fs::write(dir.join(".zshrc"), typed_rc(&dir_text, command)).is_ok()
        && std::fs::write(&script, launcher).is_ok();
    #[cfg(unix)]
    let written = written && { use std::os::unix::fs::PermissionsExt; std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).is_ok() };
    written && Command::new("open").args(["-a", "Terminal"]).arg(&script).spawn().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_typed_command_is_one_quoted_word() {
        let rc = typed_rc("/tmp/a b", "echo 'x'; rm -rf $HOME");
        assert!(rc.ends_with("print -rz -- 'echo '\\''x'\\''; rm -rf $HOME'\n"), "{rc}");
        assert!(rc.contains("rm -rf -- '/tmp/a b'\n"));
    }
}
