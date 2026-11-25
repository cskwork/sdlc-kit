//! Which addresses the board may go to, which belong to a ticket window, and which are refused.

/// Where a link from the board belongs.
#[derive(Debug, PartialEq)]
pub enum Target {
    /// This machine (127.0.0.1, localhost, ::1).
    Local,
    /// Any other http(s) page, such as a Jira ticket: the ticket window.
    External,
    /// Anything else (about:, mailto:, javascript:, file:, …).
    Other,
}

/// Whether a non-web link may go to the system's handler (`open`): only mail. Anything else (`file:` to an app,
/// `vscode:`, `x-apple.systempreferences:` …) would launch through the system, so it is refused.
pub fn system_may_open(url: &str) -> bool { url.trim_start().get(..7).is_some_and(|scheme| scheme.eq_ignore_ascii_case("mailto:")) }

pub fn classify(url: &str) -> Target {
    let url = url.trim();
    let scheme_end = url.find("://").unwrap_or(0);
    if !matches!(url[..scheme_end].to_ascii_lowercase().as_str(), "http" | "https") { return Target::Other; }
    let authority = url[scheme_end + 3..].split(['/', '?', '#', '\\']).next().unwrap_or("");
    // A user part (`127.0.0.1@evil.example`) does not name the host.
    let host_port = authority.rsplit('@').next().unwrap_or("");
    let host = match host_port.strip_prefix('[') {
        Some(rest) => rest.split(']').next().unwrap_or(""),
        None => host_port.split(':').next().unwrap_or(""),
    }.to_ascii_lowercase();
    match host.trim_end_matches('.') {
        "" => Target::Other,
        "127.0.0.1" | "localhost" | "::1" => Target::Local,
        _ => Target::External,
    }
}

/// What the board window does with a navigation.
#[derive(Debug, PartialEq)]
pub enum Navigation {
    Stay,
    /// Leaves the board: http(s) off this machine or mail.
    HandOff,
    Refuse,
}

/// The board window shows its server's pages (`board`, an `http://127.0.0.1:<port>` origin) and the shell's own page;
/// nothing else, not even another port of this machine.
pub fn navigation(to: &str, board: &str, shell: &str) -> Navigation {
    if to == "about:blank" || within(to, board) || within(to, shell) { return Navigation::Stay; }
    match classify(to) {
        Target::External => Navigation::HandOff,
        Target::Other if system_may_open(to) => Navigation::HandOff,
        _ => Navigation::Refuse,
    }
}

/// Whether `url` is a page of `origin` (`scheme://host[:port]`, no path); an empty origin has none.
pub fn within(url: &str, origin: &str) -> bool {
    !origin.is_empty() && url.strip_prefix(origin).is_some_and(|rest| rest.is_empty() || rest.starts_with(['/', '?', '#']))
}

/// The part of an address fit for a log: no path, query or fragment, which could carry a secret.
pub fn loggable(url: &str) -> String {
    let end = url.find("://").map(|at| at + 3).unwrap_or(0);
    let cut = url[end..].find(['/', '?', '#']).map(|at| end + at).unwrap_or(url.len());
    url[..cut].split('@').next_back().unwrap_or("").chars().take(80).collect::<String>().split(',').next().unwrap_or("").to_string()
}

/// The longest ticket address the board may ask for.
const TICKET_LIMIT: usize = 8 * 1024;

/// A ticket address from the page: http(s), off this machine, of a sane length.
pub fn ticket(url: &str) -> Result<(), String> {
    if url.len() > TICKET_LIMIT { return Err(format!("address of {} bytes, over {TICKET_LIMIT}", url.len())); }
    if classify(url) != Target::External || url.chars().any(char::is_control) { return Err("not a ticket address".into()); }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const BOARD: &str = "http://127.0.0.1:51860";
    const SHELL: &str = "tauri://localhost";

    #[test]
    fn board_links_and_ticket_links_are_told_apart() {
        for url in ["http://127.0.0.1:51234/#t=abc&app=1", "http://localhost:3000/x", "http://[::1]:8080/", "HTTP://127.0.0.1/"] {
            assert_eq!(classify(url), Target::Local, "{url}");
        }
        for url in ["https://example.atlassian.net/browse/PROJ-1528", "http://127.0.0.1.evil.example/", "https://127.0.0.1@evil.example/",
            "https://example.com:8443/a?b#c"] {
            assert_eq!(classify(url), Target::External, "{url}");
        }
        for url in ["about:blank", "mailto:a@b.c", "javascript:alert(1)", "file:///etc/hosts", "", "https://", "data:text/html,x"] {
            assert_eq!(classify(url), Target::Other, "{url}");
        }
    }

    #[test]
    fn only_mail_links_go_to_the_system_handler() {
        // Never to Chrome, never to `open`: these could launch an app.
        for url in ["file:///Applications/Calculator.app", "FILE:///tmp/evil.app", "data:text/html,<script>x</script>",
            "chrome://settings", "blob:http://127.0.0.1:5000/0b9c", "javascript:alert(1)", "javascript://%0aalert(1)",
            "vscode://file/etc/hosts", "x-apple.systempreferences:com.apple.preference.security", "ftp://e.x/a", "mailto"] {
            assert_eq!(classify(url), Target::Other, "{url}");
            assert!(!system_may_open(url), "{url}");
            assert_eq!(navigation(url, BOARD, SHELL), Navigation::Refuse, "{url}");
        }
        for url in ["mailto:qa@example.com", "MAILTO:qa@example.com?subject=PROJ"] {
            assert!(system_may_open(url), "{url}");
            assert_eq!(navigation(url, BOARD, SHELL), Navigation::HandOff, "{url}");
        }
    }

    #[test]
    fn the_board_window_stays_on_its_servers_origin() {
        for url in ["http://127.0.0.1:51860/#t=x&app=1", "http://127.0.0.1:51860", "http://127.0.0.1:51860/app.js", "tauri://localhost/index.html#a", "about:blank"] {
            assert_eq!(navigation(url, BOARD, SHELL), Navigation::Stay, "{url}");
        }
        // Another port, another name of this machine, or a lookalike of either is not the board.
        for url in ["http://127.0.0.1:51861/", "http://127.0.0.1:518600/", "http://localhost:51860/", "https://127.0.0.1:51860/", "http://127.0.0.1/", "http://127.0.0.1:51860.evil.example/", "tauri://localhost.evil/"] {
            assert_eq!(navigation(url, BOARD, SHELL), Navigation::Refuse, "{url}");
        }
        for url in ["https://example.com/", "http://127.0.0.1.evil.example/", "http://127.0.0.1:51860@evil.example/"] {
            assert_eq!(navigation(url, BOARD, SHELL), Navigation::HandOff, "{url}");
        }
        // Before a server is known nothing on this machine is the board.
        assert_eq!(navigation("http://127.0.0.1:51860/", "", SHELL), Navigation::Refuse);
    }

    #[test]
    fn the_page_may_ask_only_for_a_web_page_off_this_machine() {
        assert_eq!(ticket("https://example.atlassian.net/browse/PROJ-1383"), Ok(()));
        for url in ["http://127.0.0.1:51860/#t=x", "http://localhost/", "file:///Applications/Calculator.app", "javascript:alert(1)",
            "vscode://file/etc/hosts", "data:text/html,x", "mailto:a@b.c", "", "https://e.x/\n-a"] {
            assert!(ticket(url).is_err(), "{url}");
        }
        assert!(ticket(&format!("https://e.x/{}", "a".repeat(9000))).unwrap_err().contains("over 8192"));
    }

    #[test]
    fn a_logged_address_carries_no_path_query_or_token() {
        assert_eq!(loggable("http://127.0.0.1:5000/#t=0123"), "http://127.0.0.1:5000");
        assert_eq!(loggable("http://127.0.0.1:5000?t=0123"), "http://127.0.0.1:5000");
        assert_eq!(loggable("https://user:secret@e.x/a"), "e.x");
        assert_eq!(loggable("data:text/html,secret"), "data:text");
    }
}
