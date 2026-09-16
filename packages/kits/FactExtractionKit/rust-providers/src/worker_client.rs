use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::sync::mpsc::{self, Sender, Receiver};
use std::time::Duration;

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
    requests: Option<Sender<WorkerRequest>>,
    responses: Receiver<Result<WorkerResponse, String>>,
    io_thread: Option<std::thread::JoinHandle<()>>,
}

impl WorkerProcess {
    fn stop(&mut self) {
        self.requests.take();
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(thread) = self.io_thread.take() { let _ = thread.join(); }
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
    request_timeout: Duration,
}

impl NuExtractWorkerClient {
    pub fn new(config: NuExtractWorkerConfig) -> Result<Self, FactExtractionError> {
        Self::with_request_timeout(config, Duration::from_secs(60))
    }

    pub fn with_request_timeout(config: NuExtractWorkerConfig, request_timeout: Duration) -> Result<Self, FactExtractionError> {
        if request_timeout.is_zero() {
            return Err(FactExtractionError::InvalidRequest("request timeout must be positive".into()));
        }
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
            request_timeout,
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
        let mut stdin = child.stdin.take().ok_or_else(|| {
            FactExtractionError::Unavailable("NuExtract worker stdin was not piped".into())
        })?;
        let mut stdout = child.stdout.take().ok_or_else(|| {
            FactExtractionError::Unavailable("NuExtract worker stdout was not piped".into())
        })?;
        let (requests, receive_request) = mpsc::channel::<WorkerRequest>();
        let (send_response, responses) = mpsc::channel();
        let io_thread = std::thread::spawn(move || {
            while let Ok(request) = receive_request.recv() {
                let response = write_frame(&mut stdin, &request)
                    .and_then(|_| read_frame::<WorkerResponse>(&mut stdout));
                let failed = response.is_err();
                if send_response.send(response).is_err() || failed { break; }
            }
        });
        Ok(WorkerProcess { child, requests: Some(requests), responses, io_thread: Some(io_thread) })
    }

    fn exchange(
        &self,
        process: &mut WorkerProcess,
        request: &WorkerRequest,
    ) -> Result<FactExtractionResponse, FactExtractionError> {
        process.requests.as_ref().ok_or_else(|| FactExtractionError::InferenceFailed("worker stopped".into()))?
            .send(request.clone()).map_err(|error| FactExtractionError::InferenceFailed(error.to_string()))?;
        let response = match process.responses.recv_timeout(self.request_timeout) {
            Ok(result) => result.map_err(FactExtractionError::InferenceFailed)?,
            Err(mpsc::RecvTimeoutError::Timeout) => return Err(FactExtractionError::TimedOut("worker request deadline exceeded".into())),
            Err(error) => return Err(FactExtractionError::InferenceFailed(error.to_string())),
        };
        if response.protocol_version != PROTOCOL_VERSION
            || response.request_id != request.request_id
        {
            return Err(FactExtractionError::MalformedResponse(
                "NuExtract worker response protocol or request identity mismatch".into(),
            ));
        }
        match (response.result, response.error) {
            (Some(result), None) => Ok(result),
            (None, Some(error)) => Err(FactExtractionError::from_wire(response.error_code.as_deref(), error)),
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
            || request.source_text.chars().count() > self.spec.maximum_input_characters
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
            Err(FactExtractionError::MalformedResponse(_) | FactExtractionError::TimedOut(_)) => true,
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

    #[cfg(unix)]
    #[test]
    fn unresponsive_worker_times_out_and_is_reaped() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!("fact-worker-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let executable = root.join("worker.sh");
        std::fs::write(&executable, "#!/bin/sh\nexec /bin/sleep 30\n").unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let asset = root.join("asset"); std::fs::write(&asset, "{}").unwrap();
        let config = NuExtractWorkerConfig::tiny_v1_5(&executable, &asset, &asset, "test");
        let client = NuExtractWorkerClient::with_request_timeout(config, Duration::from_millis(100)).unwrap();
        let started = std::time::Instant::now();
        let result = client.extract(&FactExtractionRequest { source_id: "source".into(),
            source_digest: "digest".into(), source_text: "hello".into(),
            eligible_source_spans: vec![], maximum_facts: 4 });
        assert!(matches!(result, Err(FactExtractionError::TimedOut(_))));
        assert!(client.process.lock().unwrap().is_none());
        assert!(started.elapsed() < Duration::from_secs(5));
        std::fs::remove_dir_all(&root).unwrap();
    }

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
