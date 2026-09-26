use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::{fs, thread};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

fn jsv(files: &[PathBuf]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_jsv"))
        .args(files)
        .output()
        .unwrap()
}

fn serve_not_found() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let _ = stream.read(&mut [0; 1024]);
            let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        }
    });
    format!("http://{address}")
}

#[test]
fn schema_with_relative_id_is_valid() {
    let output = jsv(&[fixture("data/rope.json")]);
    assert!(output.status.success(), "{output:?}");
}

#[test]
fn relative_refs_resolve_next_to_the_schema() {
    let output = jsv(&[fixture("data/shield.json")]);
    assert!(output.status.success(), "{output:?}");
}

#[test]
fn errors_from_referenced_schemas_are_reported() {
    let output = jsv(&[fixture("data/overpriced-plate.json")]);
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(!output.status.success());
    assert!(stdout.contains("/cost/gp"), "{stdout}");
}

#[test]
fn missing_remote_ref_reports_the_status() {
    let dir = std::env::temp_dir().join(format!("jsv-remote-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let schema = serde_json::json!({ "$ref": format!("{}/dice.json", serve_not_found()) });
    fs::write(dir.join("schema.json"), schema.to_string()).unwrap();
    fs::write(dir.join("data.json"), r#"{ "$schema": "schema.json" }"#).unwrap();

    let output = jsv(&[dir.join("data.json")]);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success());
    assert!(stderr.contains("404"), "{stderr}");
}
