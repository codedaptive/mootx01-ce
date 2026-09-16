//! Candle-backed NuExtract 1.5 inference owned by the worker binary.

use std::fs::File;
use std::path::Path;

use candle_core::quantized::gguf_file;
use candle_core::{Device, Tensor};
use candle_transformers::models::{quantized_phi3, quantized_qwen2};
use fact_extraction_kit::{
    FactAssertionKind, FactCandidate, FactExtractionRequest, FactExtractionResponse,
    FactExtractorModelSpec, FactExtractionError,
};
use serde::Deserialize;
use tokenizers::Tokenizer;

use crate::protocol::NuExtractArchitecture;

const EXTRACTION_TEMPLATE: &str = r#"{
  "facts": [{
    "subject": "",
    "predicate": "",
    "object": "",
    "evidence": ""
  }]
}"#;

enum QuantizedModel {
    Qwen2(quantized_qwen2::ModelWeights),
    Phi3(quantized_phi3::ModelWeights),
}

impl QuantizedModel {
    fn forward(&mut self, input: &Tensor, offset: usize) -> candle_core::Result<Tensor> {
        match self {
            Self::Qwen2(model) => model.forward(input, offset),
            Self::Phi3(model) => model.forward(input, offset),
        }
    }
}

pub struct CandleNuExtract {
    model: QuantizedModel,
    tokenizer: Tokenizer,
    device: Device,
    stop_tokens: Vec<u32>,
    context_length: usize,
    maximum_new_tokens: usize,
    spec: FactExtractorModelSpec,
}

impl CandleNuExtract {
    pub fn load(
        gguf_path: &Path,
        tokenizer_path: &Path,
        architecture: NuExtractArchitecture,
        maximum_new_tokens: usize,
        spec: FactExtractorModelSpec,
    ) -> Result<Self, String> {
        #[cfg(target_os = "macos")]
        let device = Device::new_metal(0).unwrap_or(Device::Cpu);
        #[cfg(not(target_os = "macos"))]
        let device = Device::Cpu;

        let mut file = File::open(gguf_path)
            .map_err(|error| format!("open GGUF {}: {error}", gguf_path.display()))?;
        let content = gguf_file::Content::read(&mut file)
            .map_err(|error| format!("parse GGUF {}: {error}", gguf_path.display()))?;
        let context_key = match architecture {
            NuExtractArchitecture::Qwen2 => "qwen2.context_length",
            NuExtractArchitecture::Phi3 => "phi3.context_length",
        };
        let context_length = content
            .metadata
            .get(context_key)
            .ok_or_else(|| format!("GGUF is missing {context_key}"))?
            .to_u32()
            .map_err(|error| format!("read {context_key}: {error}"))?
            as usize;
        if context_length <= maximum_new_tokens + 1 {
            return Err(format!(
                "model context {context_length} does not fit generation budget {maximum_new_tokens}"
            ));
        }
        let model = match architecture {
            NuExtractArchitecture::Qwen2 => QuantizedModel::Qwen2(
                quantized_qwen2::ModelWeights::from_gguf(content, &mut file, &device)
                    .map_err(|error| format!("load Qwen2 GGUF: {error}"))?,
            ),
            NuExtractArchitecture::Phi3 => QuantizedModel::Phi3(
                quantized_phi3::ModelWeights::from_gguf(false, content, &mut file, &device)
                    .map_err(|error| format!("load Phi3 GGUF: {error}"))?,
            ),
        };
        let mut tokenizer = Tokenizer::from_file(tokenizer_path)
            .map_err(|error| format!("load tokenizer {}: {error}", tokenizer_path.display()))?;
        tokenizer
            .with_truncation(None)
            .map_err(|error| format!("disable tokenizer truncation: {error}"))?;
        let stop_tokens = ["<|endoftext|>", "<|end|>", "<|im_end|>"]
            .iter()
            .filter_map(|token| tokenizer.token_to_id(token))
            .collect();
        Ok(Self {
            model,
            tokenizer,
            device,
            stop_tokens,
            context_length,
            maximum_new_tokens,
            spec,
        })
    }

    pub fn extract(
        &mut self,
        request: &FactExtractionRequest,
    ) -> Result<FactExtractionResponse, FactExtractionError> {
        if request.maximum_facts == 0
            || request.maximum_facts > self.spec.maximum_facts_per_source
            || request.source_text.chars().count() > self.spec.maximum_input_characters
        {
            return Err(FactExtractionError::InvalidRequest("request exceeds the configured NuExtract recipe".into()));
        }
        let prompt = format!(
            "<|input|>\n### Template:\n{EXTRACTION_TEMPLATE}\n### Text:\n{}\n\n<|output|>",
            request.source_text
        );
        let raw = self.generate(&prompt)?;
        let batch = parse_first_json_object::<RawBatch>(&raw)
            .map_err(FactExtractionError::MalformedResponse)?;
        let raw_facts = batch.facts.or_else(|| batch.fact.map(|fact| vec![fact]))
            .ok_or_else(|| FactExtractionError::MalformedResponse("missing fact collection".into()))?;
        let candidates = raw_facts
            .into_iter()
            .filter(|raw| !raw.is_explicit_empty())
            .map(|raw| raw.into_candidate(&request.source_text))
            .collect();
        Ok(FactExtractionResponse {
            source_digest: request.source_digest.clone(),
            provider_id: self.spec.provider_id.clone(),
            model_id: self.spec.model_id.clone(),
            model_version: self.spec.model_version.clone(),
            schema_version: self.spec.schema_version.clone(),
            candidates,
        })
    }

    /// Token context includes the prompt/template and reserved output budget.
    fn generate(&mut self, prompt: &str) -> Result<String, FactExtractionError> {
        let encoding = self
            .tokenizer
            .encode(prompt, false)
            .map_err(|error| format!("encode NuExtract prompt: {error}"))?;
        let mut ids = encoding.get_ids().to_vec();
        let prompt_length = ids.len();
        let maximum_prompt = self.context_length - self.maximum_new_tokens - 1;
        if prompt_length == 0 || prompt_length > maximum_prompt {
            return Err(FactExtractionError::NeedsSubdivision("prompt exceeds token context including output reserve".into()));
        }

        for step in 0..self.maximum_new_tokens {
            let (input_ids, offset) = if step == 0 {
                (ids.as_slice(), 0)
            } else {
                (&ids[ids.len() - 1..], ids.len() - 1)
            };
            let input = Tensor::from_slice(input_ids, (1, input_ids.len()), &self.device)
                .map_err(|error| format!("build NuExtract input tensor: {error}"))?;
            let logits = self
                .model
                .forward(&input, offset)
                .map_err(|error| format!("run NuExtract forward pass: {error}"))?;
            let logits = logits
                .squeeze(0)
                .map_err(|error| format!("read NuExtract logits: {error}"))?;
            let next = logits
                .argmax(0)
                .and_then(|value| value.to_scalar::<u32>())
                .map_err(|error| format!("select NuExtract token: {error}"))?;
            if self.stop_tokens.contains(&next) {
                break;
            }
            ids.push(next);
            let decoded = self
                .tokenizer
                .decode(&ids[prompt_length..], true)
                .map_err(|error| format!("decode NuExtract output: {error}"))?;
            if parse_first_json_object::<serde_json::Value>(&decoded).is_ok() {
                return Ok(decoded);
            }
        }
        let decoded = self
            .tokenizer
            .decode(&ids[prompt_length..], true)
            .map_err(|error| format!("decode NuExtract output: {error}"))?;
        parse_first_json_object::<serde_json::Value>(&decoded)
            .map(|_| decoded)
            .map_err(|_| FactExtractionError::NeedsSubdivision("output ended without a complete JSON object".into()))
    }
}

#[derive(Debug, Deserialize)]
struct RawBatch {
    facts: Option<Vec<RawFact>>,
    fact: Option<RawFact>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawFact {
    subject: Option<String>,
    predicate: Option<String>,
    object: Option<String>,
    #[serde(rename = "evidence")]
    evidence_quote: Option<String>,
}

impl RawFact {
    fn is_explicit_empty(&self) -> bool {
        [&self.subject, &self.predicate, &self.object, &self.evidence_quote]
            .iter().all(|value| value.as_deref() == Some(""))
    }
    /// A missing field passes through empty; the grounding validator rejects
    /// the candidate as `EmptyField` and the other candidates in the same
    /// response survive.
    fn into_candidate(self, source_text: &str) -> FactCandidate {
        let subject = self.subject.unwrap_or_default();
        let object = self.object.unwrap_or_default();
        let evidence_quote = self
            .evidence_quote
            .filter(|value| !value.is_empty() && source_text.contains(value))
            .or_else(|| {
                source_text
                    .lines()
                    .find(|line| {
                        line.to_lowercase().contains(&subject.to_lowercase())
                            && line.to_lowercase().contains(&object.to_lowercase())
                    })
                    .map(str::to_owned)
            })
            .unwrap_or_default();
        FactCandidate {
            subject,
            predicate: self.predicate.unwrap_or_default(),
            object,
            evidence_quote,
            confidence: 0.8,
            assertion_kind: FactAssertionKind::Asserted,
            search_aliases: Vec::new(),
        }
    }
}

fn parse_first_json_object<T: for<'de> Deserialize<'de>>(raw: &str) -> Result<T, String> {
    let start = raw
        .find('{')
        .ok_or_else(|| "output contains no JSON object".to_string())?;
    let mut stream = serde_json::Deserializer::from_str(&raw[start..]).into_iter::<T>();
    match stream.next() {
        Some(Ok(value)) => Ok(value),
        Some(Err(error)) => Err(format!("decode output JSON: {error}")),
        None => Err("output contains no JSON value".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parser_accepts_one_complete_object_and_ignores_trailing_tokens() {
        let batch: RawBatch =
            parse_first_json_object("prefix {\"facts\":[]} trailing model chatter").unwrap();
        assert_eq!(batch.facts.unwrap().len(), 0);
    }

    #[test]
    fn partial_fact_reaches_grounding_with_missing_fields() {
        let batch: RawBatch = parse_first_json_object(r#"{"facts":[{"subject":"Jack"}]}"#).unwrap();
        assert!(batch
            .facts
            .unwrap()
            .remove(0)
            .into_candidate("Jack's birthday is June 20th.")
            .predicate.is_empty());
    }

    #[test]
    fn pure_extraction_output_receives_host_owned_trust_metadata() {
        let batch: RawBatch = parse_first_json_object(
            r#"{"facts":[{"subject":"Jack","predicate":"birthday","object":"June 20th","evidence":"jack's birthday is june 20th."}]}"#,
        )
        .unwrap();
        let candidate = batch
            .facts
            .unwrap()
            .remove(0)
            .into_candidate("Jack's birthday is June 20th.");
        assert_eq!(candidate.confidence, 0.8);
        assert_eq!(candidate.assertion_kind, FactAssertionKind::Asserted);
        assert!(candidate.search_aliases.is_empty());
    }
}
