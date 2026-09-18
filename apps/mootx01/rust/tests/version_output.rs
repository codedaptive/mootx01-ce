use std::process::Command;

#[test]
fn version_reports_the_product_converter_identities() {
    let output = Command::new(env!("CARGO_BIN_EXE_mootx01"))
        .arg("--version")
        .output()
        .expect("run mootx01 --version");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).expect("version output is UTF-8");
    let hydration = genius_locus_kit::DISTILLATION_CONVERTER;
    let recall = aria_mcp::recall_distillation::CONVERTER;
    assert_eq!(
        stdout,
        format!(
            "{} ({})\nconverter hydration {} {}\nconverter recall {} {}\n",
            mootx01_cli::CURRENT_VERSION,
            mootx01_cli::RELEASE_DATE,
            hydration.id(),
            hydration.converter_version(),
            recall.id(),
            recall.converter_version(),
        )
    );
}
