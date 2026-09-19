# AI Knowledge for Judge Adapters

Judge adapters implement one contract: prompt on stdin, answer or verdict on
stdout, and a meaningful nonzero exit on failure. They do not change retrieval
scores and are used only by model-attributable answer-quality phases.

Model, version, quantization, grading mode, and runtime identity must be
recorded beside judged figures. Credentials and commands belong in environment
variables. Build products and transcripts remain under `BENCH_WORK_ROOT`.
