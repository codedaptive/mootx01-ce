//! Light benchmark for eidetic_lib. Measures cold-start and
//! warm word-class tagging performance. Run with `cargo bench` or
//! treat as a standalone binary.
//!
//! Numbers are wall-clock and printed in microseconds. For
//! tighter measurements use the `criterion` crate; this
//! harness aims to give a rough "is this fast enough" check
//! without a heavyweight dependency.
//!
//! `lookup` is a not-implemented stub until the FDC runtime
//! (GNO-FDC-06/07) lands, so this benchmark exercises the live
//! Step 1 primitive, `word_class`, instead.

use eidetic_lib::word_class::word_class;
use std::time::Instant;

fn bench<F>(label: &str, iters: u32, mut f: F)
where
    F: FnMut(),
{
    // Warm up.
    for _ in 0..10 {
        f();
    }
    let start = Instant::now();
    for _ in 0..iters {
        f();
    }
    let elapsed = start.elapsed();
    let per_iter_us =
        elapsed.as_nanos() as f64 / 1000.0 / iters as f64;
    let total_ms = elapsed.as_secs_f64() * 1000.0;
    println!(
        "  {:<40}  {:>8.2} µs/iter  {:>8.2} ms total  ({} iters)",
        label, per_iter_us, total_ms, iters
    );
}

fn main() {
    println!("eidetic_lib benchmark");
    println!("====================");
    println!();

    // Cold start: first call pays for the static table parse and
    // index construction inside word_class.
    let start = Instant::now();
    let _ = word_class("chemistry");
    let cold = start.elapsed();
    println!(
        "Cold start (first word_class): {:.2} ms",
        cold.as_secs_f64() * 1000.0
    );
    println!();

    println!("Warm word_class timings:");

    bench("chemistry", 10_000, || {
        let _ = word_class("chemistry");
    });

    bench("organic", 10_000, || {
        let _ = word_class("organic");
    });

    bench("programming", 10_000, || {
        let _ = word_class("programming");
    });

    bench("psychology", 10_000, || {
        let _ = word_class("psychology");
    });

    bench("qwertyzxcvb (novel token)", 10_000, || {
        let _ = word_class("qwertyzxcvb");
    });

    bench("empty input", 10_000, || {
        let _ = word_class("");
    });

    println!();
    println!("Done.");
}
