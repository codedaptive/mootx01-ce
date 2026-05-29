// src/bin/gen_vectors.rs
//
// CLI: `cargo run --bin gen-vectors -- --primitive <name> --seed <0xhex> [--out <path>]`
//
// Mirrors the Swift gen-vectors binary.

use std::env;
use std::fs;
use std::process;

use harness::{find_primitive, all_primitives, decode_hex, JsonWriter, u32_hex};
use harness::kernel_selector;

fn usage() -> ! {
    eprintln!(
        "usage: gen-vectors --primitive <name> --seed <0xhex> [--out <path>] [--kernel <name>]\n\
         \n\
         Kernels: scalar (default), simd\n\
         \n\
         Available primitives:"
    );
    for p in all_primitives() {
        eprintln!("  - {} ({})", p.name, p.cookbook_section);
    }
    process::exit(2);
}

fn parse_seed(s: &str) -> u64 {
    let bytes = decode_hex(s).unwrap_or_else(|e| {
        eprintln!("invalid seed: {e}");
        process::exit(2);
    });
    if bytes.len() != 8 {
        eprintln!("seed must be 8 bytes (16 hex digits)");
        process::exit(2);
    }
    let mut v = 0u64;
    for (i, b) in bytes.iter().enumerate() {
        v |= (*b as u64) << (i * 8);
    }
    v
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut primitive: Option<String> = None;
    let mut seed: Option<u64> = None;
    let mut out: Option<String> = None;
    let mut kernel_name: String = "scalar".to_string();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--primitive" => {
                i += 1;
                if i >= args.len() {
                    usage();
                }
                primitive = Some(args[i].clone());
            }
            "--seed" => {
                i += 1;
                if i >= args.len() {
                    usage();
                }
                seed = Some(parse_seed(&args[i]));
            }
            "--out" => {
                i += 1;
                if i >= args.len() {
                    usage();
                }
                out = Some(args[i].clone());
            }
            "--kernel" => {
                i += 1;
                if i >= args.len() {
                    usage();
                }
                kernel_name = args[i].clone();
            }
            _ => usage(),
        }
        i += 1;
    }
    let primitive = primitive.unwrap_or_else(|| usage());
    let seed = seed.unwrap_or_else(|| usage());

    let kind = kernel_selector::parse(&kernel_name).unwrap_or_else(|| {
        eprintln!("unknown kernel: {kernel_name}");
        process::exit(2);
    });
    kernel_selector::set(kind);

    let descriptor = find_primitive(&primitive).unwrap_or_else(|| {
        eprintln!("unknown primitive: {primitive}");
        usage();
    });

    let file = (descriptor.generate)(seed).unwrap_or_else(|e| {
        eprintln!("generation failed: {e}");
        process::exit(1);
    });

    let json = JsonWriter::write(&file);

    let output_path = match out {
        Some(p) => p,
        None => {
            let cwd = env::current_dir().expect("cwd");
            let harness_root = env::var("GLREF_HARNESS_ROOT")
                .unwrap_or_else(|_| cwd.display().to_string());
            format!("{}/../vectors/{}.json", harness_root, descriptor.name)
        }
    };

    fs::write(&output_path, &json).unwrap_or_else(|e| {
        eprintln!("write failed: {e}");
        process::exit(1);
    });

    println!("wrote {output_path}");
    println!("  primitive: {}", descriptor.name);
    println!("  cookbook:  {}", descriptor.cookbook_section);
    println!("  cases:     {}", file.cases.len());
    println!("  crc32:     {}", u32_hex(file.output_crc32));
}
