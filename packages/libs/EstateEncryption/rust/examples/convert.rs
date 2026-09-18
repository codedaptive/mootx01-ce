//! convert — one-shot plaintext-to-encrypted conversion, for cross-port
//! conformance runs.
//!
//! Usage: convert <source.sqlite> <dest.sqlite> <key-hex>
//!
//! Exists so the Rust port can be driven over the same input the Swift port
//! receives, and the two outputs compared. It performs the same conversion the
//! product does and nothing else.

use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: convert <source> <dest> <key-hex>");
        std::process::exit(2);
    }
    let key: Vec<u8> = (0..args[3].len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&args[3][i..i + 2], 16).expect("key hex"))
        .collect();

    match estate_encryption::export_encrypted_copy(
        Path::new(&args[1]),
        Path::new(&args[2]),
        &key,
    ) {
        Ok(()) => {
            let counts = estate_encryption::verification_counts(Path::new(&args[2]), Some(&key))
                .expect("counts");
            println!("{counts}");
        }
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
