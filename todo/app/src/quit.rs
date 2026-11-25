//! Ending the app: at once, or after the page has asked about what is not sent yet.
use crate::{board, lock, Shell};
use tauri::{AppHandle, Manager};

/// Quit, from the tray, the menu (⌘Q) or the Dock.
pub fn request(app: &AppHandle) {
    if may_end(app) { return end(app); }
    // A question that could not be shown is not a yes: the app stays, with the page and what it carries.
    board::later(app, |app| if !board::ask_quit(app) {
        eprintln!("sdlc-todo: could not ask before quitting; staying open");
        board::show(app, board::current_view());
    });
}

/// Whether nothing unsent would be lost, as the page last said.
fn may_end(app: &AppHandle) -> bool {
    let shell = app.state::<Shell>();
    let shared = lock(&shell.shared);
    shared.leaving || (!shared.unsent && lock(&shell.carried).is_none())
}

pub fn end(app: &AppHandle) {
    lock(&app.state::<Shell>().shared).leaving = true;
    app.exit(0);
}

/// ⌘Q, the Dock's Quit and a logout end the app through `terminate:`, which tao does not let anyone answer. This adds
/// the answer to its application delegate.
#[cfg(target_os = "macos")]
pub fn answer_terminate(app: &AppHandle) {
    use objc2::ffi::class_addMethod;
    use objc2::runtime::{AnyClass, AnyObject, Imp, Sel};
    use objc2::{class, msg_send, sel};
    static APP: std::sync::OnceLock<AppHandle> = std::sync::OnceLock::new();
    const CANCEL: usize = 0;
    const NOW: usize = 1;
    extern "C-unwind" fn should_terminate(_: *mut AnyObject, _: Sel, _: *mut AnyObject) -> usize {
        let Some(app) = APP.get() else { return NOW };
        if may_end(app) { return NOW; }
        request(app);
        CANCEL
    }
    let _ = APP.set(app.clone());
    // Safety: on the main thread (RunEvent::Ready). The method has the signature AppKit declares
    // (NSUInteger, self, _cmd, sender); class_addMethod changes nothing when the class already has one.
    unsafe {
        let delegate: *mut AnyObject = msg_send![{ let shared: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication]; shared }, delegate];
        if delegate.is_null() { return; }
        let class: *const AnyClass = (*delegate).class();
        let answer: extern "C-unwind" fn(*mut AnyObject, Sel, *mut AnyObject) -> usize = should_terminate;
        class_addMethod(class.cast_mut(), sel!(applicationShouldTerminate:), std::mem::transmute::<extern "C-unwind" fn(*mut AnyObject, Sel, *mut AnyObject) -> usize, Imp>(answer), c"Q@:@".as_ptr());
    }
}
