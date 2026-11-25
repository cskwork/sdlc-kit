//! The desktop program; everything lives in the library so mobile targets can share it.
#![cfg_attr(windows, windows_subsystem = "windows")]

fn main() { sdlc_todo_lib::run(); }
