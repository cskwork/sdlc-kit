//! The app's own words, in the kit's two UI languages; the status wording matches `todo/locales`.
#[derive(Clone, Copy, PartialEq)]
pub enum Lang { En, Ko }

impl Lang {
    pub fn parse(value: &str) -> Lang { if value.starts_with("ko") { Lang::Ko } else { Lang::En } }
}

pub fn t(lang: Lang, key: &str) -> &'static str {
    let (en, ko) = match key {
        "title" => ("To-do", "할 일"),
        "you" => ("Your turn", "내 차례"),
        "agent" => ("Agent", "에이전트"),
        "blocked" => ("Blocked", "막힘"),
        "done" => ("Done", "완료"),
        "tab.focus" => ("Needs you", "확인 필요"),
        "tab.agent" => ("In progress", "진행 중"),
        "tab.all" => ("All", "전체"),
        "tab.done" => ("Done", "완료"),
        "status.approve-intent" => ("Approve scope", "범위 승인 필요"),
        "status.approve-plan" => ("Approve plan", "계획 승인 필요"),
        "status.answer" => ("Needs your answer", "답변 필요"),
        "status.agent" => ("Agent working", "에이전트 진행 중"),
        "status.handoff" => ("Answered — not picked up yet", "답변 전달됨 — 에이전트 수신 전"),
        "status.new" => ("Not started", "시작 전"),
        "status.blocked" => ("Blocked — needs action", "막힘 — 조치 필요"),
        "status.done" => ("Done", "완료"),
        "live" => ("Live", "실시간"),
        "connecting" => ("Connecting…", "연결 중…"),
        "offline" => ("Offline", "연결 끊김"),
        "empty.focus" => ("Nothing needs you. Agents keep working.", "확인할 일이 없어요. 에이전트가 계속 일하는 중이에요."),
        "empty" => ("Nothing here.", "항목이 없어요."),
        "waits" => ("Waiting for", "기다리는 것"),
        "problem" => ("Problem", "문제"),
        "history" => ("Recent history", "최근 기록"),
        "reply.hint" => ("Type your answer (one line)", "답변을 한 줄로 적어 주세요"),
        "reply.send" => ("Send answer", "답변 보내기"),
        "reply.sent" => ("Answer sent", "답변 보냄"),
        "reply.help" => ("An answer is input for the agent, never an approval.", "답변은 에이전트에게 주는 입력이고 승인이 아니에요."),
        "approve.open" => ("Read document", "문서 보기"),
        "approve.note" => ("Note (optional)", "메모 (선택)"),
        "approve.button" => ("Approve this version", "이 버전 승인"),
        "approve.done" => ("Approved", "승인함"),
        "approve.loading" => ("Loading document…", "문서 불러오는 중…"),
        "fix.button" => ("Fix by agent", "자가 조치"),
        "fix.help" => ("An agent reads this block and clears it; it asks you only when a decision is yours.", "에이전트가 막힌 원인을 읽고 직접 풀어요. 사람이 정해야 할 때만 물어봐요."),
        "fix.started" => ("Fix requested; an agent started", "자가 조치 요청됨 — 에이전트 시작"),
        "fix.queued" => ("Fix requested; the next agent run picks it up", "자가 조치 요청됨 — 다음 에이전트 실행 때 처리"),
        "fix.failed" => ("Fix requested, but no agent started: ", "자가 조치 요청됨, 에이전트 시작 실패: "),
        "open.link" => ("Open ticket", "티켓 열기"),
        "open.web" => ("Open in browser", "브라우저에서 열기"),
        "tray.open" => ("Open To-do", "할 일 열기"),
        "tray.web" => ("Open in browser", "브라우저에서 열기"),
        "tray.quit" => ("Quit", "종료"),
        "notify.title" => ("To-do needs you", "할 일 — 확인 필요"),
        "server.failed" => ("Could not reach the to-do server: ", "할 일 서버에 연결하지 못했어요: "),
        _ => ("", ""),
    };
    if lang == Lang::Ko { ko } else { en }
}
