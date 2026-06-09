fn main() {
    // Embed the app icon + version metadata into the Windows binaries so
    // Explorer, the taskbar, and the title bar show the Zentty icon.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        winresource::WindowsResource::new()
            .set_icon("assets/zentty.ico")
            .set("ProductName", "Zentty")
            .set("FileDescription", "Zentty terminal")
            .compile()
            .expect("failed to embed Windows resources (icon)");
    }
}
