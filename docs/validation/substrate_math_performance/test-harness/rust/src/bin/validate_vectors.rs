// src/bin/validate_vectors.rs
//
// CLI: `cargo run --bin validate-vectors -- <path>`
//
// Mirrors the Swift validate-vectors binary.

use std::env;
use std::fs;
use std::process;

use harness::{find_primitive, u32_hex, JsonReader};
use harness::kernel_selector;

fn usage() -> ! {
    eprintln!("usage: validate-vectors <path-to-vector-json> [--kernel <name>]");
    process::exit(2);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut path: Option<String> = None;
    let mut kernel_name: String = "scalar".to_string();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--kernel" => {
                i += 1;
                if i >= args.len() {
                    usage();
                }
                kernel_name = args[i].clone();
            }
            a if a.starts_with("--") => usage(),
            _ => {
                if path.is_some() {
                    usage();
                }
                path = Some(args[i].clone());
            }
        }
        i += 1;
    }
    let path = path.unwrap_or_else(|| usage());

    let kind = kernel_selector::parse(&kernel_name).unwrap_or_else(|| {
        eprintln!("unknown kernel: {kernel_name}");
        process::exit(2);
    });
    kernel_selector::set(kind);

    let json = fs::read_to_string(&path).unwrap_or_else(|e| {
        eprintln!("cannot read {path}: {e}");
        process::exit(1);
    });

    let file = JsonReader::parse_vector_file(&json).unwrap_or_else(|e| {
        eprintln!("malformed vector file: {e}");
        process::exit(1);
    });

    let descriptor = find_primitive(&file.primitive).unwrap_or_else(|| {
        eprintln!("unknown primitive in file: {}", file.primitive);
        process::exit(1);
    });

    let result = (descriptor.validate)(&file).unwrap_or_else(|e| {
        eprintln!("validator error: {e}");
        process::exit(1);
    });

    println!("validating {path}");
    println!("  primitive: {}  ({})", file.primitive, file.cookbook_section);
    println!(
        "  generator: {} v{}",
        file.generator.language, file.generator.harness_version
    );
    println!("  cases:     {}", file.cases.len());

    let failed: Vec<_> = result.case_results.iter().filter(|r| !r.passed).collect();
    for r in &failed {
        println!(
            "  FAIL {}: {}",
            r.id,
            r.diagnostic.as_deref().unwrap_or("(no diagnostic)")
        );
    }
    if !failed.is_empty() {
        println!(
            "  {} of {} cases failed",
            failed.len(),
            result.case_results.len()
        );
    }
    println!("  crc expected: {}", u32_hex(result.crc_expected));
    println!("  crc actual:   {}", u32_hex(result.crc_actual));
    if result.crc_expected != result.crc_actual {
        println!("  CRC MISMATCH");
    }
    if result.passed {
        println!("PASS");
        process::exit(0);
    } else {
        println!("FAIL");
        process::exit(1);
    }
}
