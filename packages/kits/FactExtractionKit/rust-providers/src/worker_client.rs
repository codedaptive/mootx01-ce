use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use fact_extraction_kit::{
    FactExtractionError, FactExtractionRequest, FactExtractionResponse, FactExtractor,
    FactExtractorKind, FactExtractorModelSpec,
};

use crate::protocol::{
    read_frame, write_frame, NuExtractArchitecture, WorkerRequest, WorkerResponse, PROTOCOL_VERSION,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NuExtractWorkerConfig {
    pub executable_path: PathBuf,
    pub gguf_path: PathBuf,
    pub tokenizer_path: PathBuf,
    pub architecture: NuExtractArchitecture,
    pub model_id: String,
    pub model_version: String,
    pub schema_version: String,
    pub maximum_input_characters: usize,
    pub maximum_facts_per_source: usize,
    pub maximum_new_tokens: usize,
}

impl NuExtractWorkerConfig {
    pub fn tiny_v1_5(
        executable_path: impl Into<PathBuf>,
        gguf_path: impl Into<PathBuf>,
        tokenizer_path: impl Into<PathBuf>,
        model_version: impl Into<String>,
    ) -> Self {
        Self {
            executable_path: executable_path.into(),
            gguf_path: gguf_path.into(),
            tokenizer_path: tokenizer_path.into(),
            architecture: NuExtractArchitecture::Qwen2,
            model_id: "numind/NuExtract-1.5-tiny".into(),
            model_version: model_version.into(),
            schema_version: "kgfact-extraction-v1".into(),
            maximum_input_characters: 12_000,
            maximum_facts_per_source: 16,
            maximum_new_tokens: 1_024,
        }
    }

    pub fn full_v1_5(
        executable_path: impl Into<PathBuf>,
        gguf_path: impl Into<PathBuf>,
        tokenizer_path: impl Into<PathBuf>,
        model_version: impl Into<String>,
    ) -> Self {
        Self {
            executable_path: executable_path.into(),
            gguf_path: gguf_path.into(),
            tokenizer_path: tokenizer_path.into(),
            architecture: NuExtractArchitecture::Phi3,
            model_id: "numind/NuExtract-1.5".into(),
            model_version: model_version.into(),
            schema_version: "kgfact-extraction-v1".into(),
            maximum_input_characters: 64_000,
            maximum_facts_per_source: 32,
            maximum_new_tokens: 2_048,
        }
    }

    fn validate(&self) -> Result<(), FactExtractionError> {
        for (label, path) in [
            ("worker executable", &self.executable_path),
            ("GGUF model", &self.gguf_path),
            ("tokenizer", &self.tokenizer_path),
        ] {
            let metadata = std::fs::metadata(path).map_err(|error| {
                FactExtractionError::Unavailable(format!(
                    "{label} {} is unavailable: {error}",
                    path.display()
                ))
            })?;
            if !metadata.is_file() {
                return Err(FactExtractionError::Unavailable(format!(
                    "{label} {} is not a regular file",
                    path.display()
                )));
            }
        }
        if self.model_id.is_empty()
            || self.model_version.is_empty()
            || self.schema_version.is_empty()
            || self.maximum_input_characters == 0
            || self.maximum_facts_per_source == 0
            || self.maximum_new_tokens == 0
        {
            return Err(FactExtractionError::InvalidRequest(
                "NuExtract worker configuration contains an empty identity or zero bound".into(),
            ));
        }
        Ok(())
    }
}

struct WorkerProcess {
    child: Child,
    stdin: ChildStdin,
    stdout: ChildStdout,
}

impl WorkerProcess {
    fn stop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for WorkerProcess {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Synchronous provider facade over one isolated resident worker. The mutex
/// serializes requests because the worker owns a single model and KV cache.
/// Dropping this client closes stdin and reaps the process, releasing weights.
pub struct NuExtractWorkerClient {
    config: NuExtractWorkerConfig,
    spec: FactExtractorModelSpec,
    process: Mutex<Option<WorkerProcess>>,
    next_request_id: AtomicU64,
}

impl NuExtractWorkerClient {
    pub fn new(config: NuExtractWorkerConfig) -> Result<Self, FactExtractionError> {
        config.validate()?;
        let spec = FactExtractorModelSpec {
            provider_id: "nuextract-candle-worker".into(),
            model_id: config.model_id.clone(),
            model_version: config.model_version.clone(),
            schema_version: config.schema_version.clone(),
            extractor_kind: FactExtractorKind::SpecializedModel,
            maximum_input_characters: config.maximum_input_characters,
            maximum_facts_per_source: config.maximum_facts_per_source,
        };
        Ok(Self {
            config,
            spec,
            process: Mutex::new(None),
            next_request_id: AtomicU64::new(1),
        })
    }

    fn start(&self) -> Result<WorkerProcess, FactExtractionError> {
        let mut command = Command::new(&self.config.executable_path);
        command
            .arg("--gguf")
            .arg(&self.config.gguf_path)
            .arg("--tokenizer")
            .arg(&self.config.tokenizer_path)
            .arg("--architecture")
            .arg(self.config.architecture.argument())
            .arg("--model-id")
            .arg(&self.config.model_id)
            .arg("--model-version")
            .arg(&self.config.model_version)
            .arg("--schema-version")
            .arg(&self.config.schema_version)
            .arg("--maximum-input-characters")
            .arg(self.config.maximum_input_characters.to_string())
            .arg("--maximum-facts")
            .arg(self.config.maximum_facts_per_source.to_string())
            .arg("--maximum-new-tokens")
            .arg(self.config.maximum_new_tokens.to_string())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        let mut child = command.spawn().map_err(|error| {
            FactExtractionError::Unavailable(format!("start NuExtract worker: {error}"))
        })?;
        let stdin = child.stdin.take().ok_or_else(|| {
            FactExtractionError::Unavailable("NuExtract worker stdin was not piped".into())
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            FactExtractionError::Unavailable("NuExtract worker stdout was not piped".into())
        })?;
        Ok(WorkerProcess {
            child,
            stdin,
            stdout,
        })
    }

    fn exchange(
        &self,
        process: &mut WorkerProcess,
        request: &WorkerRequest,
    ) -> Result<FactExtractionResponse, FactExtractionError> {
        write_frame(&mut process.stdin, request).map_err(FactExtractionError::InferenceFailed)?;
        let response: WorkerResponse =
            read_frame(&mut process.stdout).map_err(FactExtractionError::InferenceFailed)?;
        if response.protocol_version != PROTOCOL_VERSION
            || response.request_id != request.request_id
        {
            return Err(FactExtractionError::MalformedResponse(
                "NuExtract worker response protocol or request identity mismatch".into(),
            ));
        }
        match (response.result, response.error) {
            (Some(result), None) => Ok(result),
            (None, Some(error)) => Err(FactExtractionError::InferenceFailed(error)),
            _ => Err(FactExtractionError::MalformedResponse(
                "NuExtract worker returned an invalid result/error envelope".into(),
            )),
        }
    }
}

impl FactExtractor for NuExtractWorkerClient {
    fn spec(&self) -> &FactExtractorModelSpec {
        &self.spec
    }

    fn extract(
        &self,
        request: &FactExtractionRequest,
    ) -> Result<FactExtractionResponse, FactExtractionError> {
        if request.maximum_facts == 0
            || request.maximum_facts > self.spec.maximum_facts_per_source
            || request.distilled_text.chars().count() > self.spec.maximum_input_characters
        {
            return Err(FactExtractionError::InvalidRequest(
                "request exceeds the configured NuExtract recipe".into(),
            ));
        }
        let mut slot = self.process.lock().map_err(|_| {
            FactExtractionError::Unavailable("NuExtract worker lock is poisoned".into())
        })?;
        if slot.is_none() {
            *slot = Some(self.start()?);
        }
        let request = WorkerRequest {
            protocol_version: PROTOCOL_VERSION,
            request_id: self.next_request_id.fetch_add(1, Ordering::Relaxed),
            extraction: request.clone(),
        };
        let result = self.exchange(slot.as_mut().expect("worker was installed"), &request);
        let should_discard = match &result {
            Ok(_) => false,
            Err(FactExtractionError::MalformedResponse(_)) => true,
            Err(_) => slot
                .as_mut()
                .and_then(|process| process.child.try_wait().ok())
                .flatten()
                .is_some(),
        };
        if should_discard {
            if let Some(mut failed) = slot.take() {
                failed.stop();
            }
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_assets_fail_before_a_process_can_start() {
        let config = NuExtractWorkerConfig::tiny_v1_5(
            "/definitely/missing/worker",
            "/definitely/missing/model.gguf",
            "/definitely/missing/tokenizer.json",
            "q8_0-test",
        );
        assert!(matches!(
            NuExtractWorkerClient::new(config),
            Err(FactExtractionError::Unavailable(_))
        ));
    }
}
