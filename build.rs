use std::{env, path::PathBuf, process::Command};
fn main() {
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let object = out.join("bridge.o");
    assert!(Command::new("clang")
        .args([
            "-fobjc-arc",
            "-O2",
            "-Wall",
            "-Wextra",
            "-c",
            "src/bridge.m",
            "-o"
        ])
        .arg(&object)
        .status()
        .unwrap()
        .success());
    assert!(Command::new("ar")
        .arg("rcs")
        .arg(out.join("libpairbridge.a"))
        .arg(object)
        .status()
        .unwrap()
        .success());
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=pairbridge");
    for name in ["Foundation", "CoreAudio", "AudioToolbox"] {
        println!("cargo:rustc-link-lib=framework={name}");
    }
    println!("cargo:rustc-link-lib=objc");
    println!("cargo:rerun-if-changed=src/bridge.m");
}
