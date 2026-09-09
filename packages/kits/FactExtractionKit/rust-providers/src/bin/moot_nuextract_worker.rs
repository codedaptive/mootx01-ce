use std::collections::BTreeMap;
use std::io::{stdin, stdout};
use std::path::PathBuf;

use fact_extraction_kit::{FactExtractorKind, FactExtractorModelSpec};
use fact_extraction_kit_providers::candle_nuextract::CandleNuExtract;
use fact_extraction_kit_providers::protocol::{
    read_frame_or_eof, write_frame, NuExtractArchitecture, WorkerRequest, WorkerResponse,
    PROTOCOL_VERSION,
};

struct Configuration {
    gguf: PathBuf,
    tokenizer: PathBuf,
    architecture: NuExtractArchitecture,
    maximum_new_tokens: usize,
    spec: FactExtractorModelSpec,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("moot-nuextract-worker: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let config = parse_arguments(std::env::args().skip(1))?;
    let mut extractor = CandleNuExtract::load(
        &config.gguf,
        &config.tokenizer,
        config.architecture,
        config.maximum_new_tokens,
        config.spec,
    )?;
    let mut input = stdin().lock();
    let mut output = stdout().lock();
    while let Some(request) = read_frame_or_eof::<WorkerRequest>(&mut input)? {
        let request_id = request.request_id;
        let response = if request.protocol_version != PROTOCOL_VERSION {
            WorkerResponse::failure(request_id, "unsupported worker protocol version")
        } else {
            match extractor.extract(&request.extraction) {
                Ok(result) => WorkerResponse::success(request_id, result),
                Err(error) => WorkerResponse::failure(request_id, error),
            }
        };
        write_frame(&mut output, &response)?;
    }
    Ok(())
}

fn parse_arguments(arguments: impl Iterator<Item = String>) -> Result<Configuration, String> {
    let mut arguments = arguments;
    let mut values = BTreeMap::new();
    while let Some(flag) = arguments.next() {
        if !flag.starts_with("--") {
            return Err(format!("unexpected argument {flag:?}"));
        }
        let value = arguments
            .next()
            .ok_or_else(|| format!("missing value for {flag}"))?;
        if values.insert(flag.clone(), value).is_some() {
            return Err(format!("duplicate argument {flag}"));
        }
    }
    let take = |values: &mut BTreeMap<String, String>, name: &str| {
        values
            .remove(name)
            .ok_or_else(|| format!("missing required argument {name}"))
    };
    let parse_usize = |values: &mut BTreeMap<String, String>, name: &str| {
        let raw = take(values, name)?;
        raw.parse::<usize>()
            .map_err(|error| format!("invalid {name} value {raw:?}: {error}"))
    };
    let gguf = PathBuf::from(take(&mut values, "--gguf")?);
    let tokenizer = PathBuf::from(take(&mut values, "--tokenizer")?);
    let architecture = match take(&mut values, "--architecture")?.as_str() {
        "qwen2" => NuExtractArchitecture::Qwen2,
        "phi3" => NuExtractArchitecture::Phi3,
        value => return Err(format!("unsupported architecture {value:?}")),
    };
    let model_id = take(&mut values, "--model-id")?;
    let model_version = take(&mut values, "--model-version")?;
    let schema_version = take(&mut values, "--schema-version")?;
    let maximum_input_characters = parse_usize(&mut values, "--maximum-input-characters")?;
    let maximum_facts_per_source = parse_usize(&mut values, "--maximum-facts")?;
    let maximum_new_tokens = parse_usize(&mut values, "--maximum-new-tokens")?;
    if !values.is_empty() {
        return Err(format!(
            "unknown arguments: {:?}",
            values.keys().collect::<Vec<_>>()
        ));
    }
    if maximum_input_characters == 0 || maximum_facts_per_source == 0 || maximum_new_tokens == 0 {
        return Err("numeric bounds must be greater than zero".into());
    }
    Ok(Configuration {
        gguf,
        tokenizer,
        architecture,
        maximum_new_tokens,
        spec: FactExtractorModelSpec {
            provider_id: "nuextract-candle-worker".into(),
            model_id,
            model_version,
            schema_version,
            extractor_kind: FactExtractorKind::SpecializedModel,
            maximum_input_characters,
            maximum_facts_per_source,
        },
    })
}
