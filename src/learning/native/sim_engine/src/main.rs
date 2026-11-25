//! `ml_sim`: reads one JSON request line on stdin (at most 64 KiB), writes the result on stdout.
//! Exit status 0 on success; 2 with `{"error": "..."}` otherwise. No file, network or user code.

use std::io::{BufRead, Read, Write};
use std::process::exit;

fn main() {
    let mut line = String::new();
    let stdin = std::io::stdin();
    let mut input = stdin.lock().take(sim_engine::MAX_INPUT as u64 + 1);
    if input.read_line(&mut line).is_err() {
        fail("unreadable input");
    }
    match sim_engine::run_request(&line) {
        Ok(reply) => {
            let mut out = std::io::stdout().lock();
            if out.write_all(reply.as_bytes()).and_then(|_| out.flush()).is_err() {
                exit(3);
            }
        }
        Err(message) => fail(&message),
    }
}

fn fail(message: &str) -> ! {
    let escaped: String = message.chars().filter(|c| c.is_ascii_graphic() || *c == ' ').collect();
    println!("{{\"error\":\"{}\"}}", escaped.replace('"', "'"));
    exit(2)
}
