// EstateSeamsTests.swift — estate-seam unit tests.
//
// Embedding-provider seam tests (provisionEmbeddingProviderSeam,
// verifyEmbeddingProviderSeam, assertEmbeddingProviderCacheDirIsolation)
// live in EstateSeamsEmbeddingTests.swift. All three suites touch
// MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER and must run serially — they are
// nested under a single .serialized parent suite there to prevent the
// setenv/unsetenv races that occur when separate top-level suites run
// concurrently across files.
