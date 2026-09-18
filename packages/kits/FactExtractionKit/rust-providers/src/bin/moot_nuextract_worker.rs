fn main() {
    if let Err(error) = fact_extraction_kit_providers::worker_command::run_from_args() {
        eprintln!("moot-nuextract-worker: {error}");
        std::process::exit(1);
    }
}
