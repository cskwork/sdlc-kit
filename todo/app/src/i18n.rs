//! The shell's own words (tray, notifications, the page shown while the server is away), in the kit's two UI
//! languages; the board's words are in `todo/locales`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Lang { En, Ko }

impl Lang {
    pub fn parse(value: &str) -> Lang { if value.starts_with("ko") { Lang::Ko } else { Lang::En } }
    pub fn code(self) -> &'static str { if self == Lang::Ko { "ko" } else { "en" } }
}

pub fn t(lang: Lang, key: &str) -> &'static str {
    let (en, ko) = match key {
        "title" => ("To-do", "할 일"),
        "tab.focus" => ("Needs you", "확인 필요"),
        "status.approve-intent" => ("Approve scope", "범위 승인 필요"),
        "status.approve-plan" => ("Approve plan", "계획 승인 필요"),
        "status.answer" => ("Needs your answer", "답변 필요"),
        "status.blocked" => ("Blocked — needs action", "막힘 — 조치 필요"),
        "connecting" => ("Starting the to-do server…", "할 일 서버를 시작하는 중…"),
        "offline" => ("The to-do server is not answering", "할 일 서버에 연결하지 못했어요"),
        "offline.hint" => ("It is tried again every few seconds; the board opens as soon as it answers.", "몇 초마다 다시 연결해요. 연결되면 보드가 바로 열려요."),
        "tray.board" => ("Open board", "보드 열기"),
        "tray.list" => ("Open list", "목록 열기"),
        "tray.quit" => ("Quit", "끝내기"),
        "notify.title" => ("To-do needs you", "할 일 — 확인 필요"),
        _ => ("", ""),
    };
    if lang == Lang::Ko { ko } else { en }
}
