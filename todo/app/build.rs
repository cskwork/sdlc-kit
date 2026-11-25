fn main() {
    // Naming the commands puts every one behind an explicit capability; none is open by default.
    let commands = tauri_build::AppManifest::new().commands(&["ticket", "app_state", "save_memo", "save_view", "open_terminal", "unsent", "quit"]);
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(commands)).expect("tauri build");
}
