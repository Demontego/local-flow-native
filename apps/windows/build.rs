fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let mut res = winresource::WindowsResource::new();
    res.set_icon("assets/app-icon.ico");
    res.set("FileDescription", "Local Flow");
    res.set("ProductName", "Local Flow");
    res.set("InternalName", "local-flow-windows");
    res.set("OriginalFilename", "local-flow-windows.exe");
    if let Err(e) = res.compile() {
        // Non-Windows hosts never hit this; on Windows fail the build.
        panic!("winresource: {e}");
    }
}
