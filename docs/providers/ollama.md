# OllamaProvider

Use native Ollama APIs for local runtime management.

**Requires:** `Ollama` trait (`#if CONDUIT_TRAIT_OLLAMA`)

## Overview

Conduit supports Ollama in two layers:

- `OpenAIProvider(endpoint: .ollama())` remains the simple OpenAI-compatible text-generation path.
- `OllamaProvider` exposes native runtime operations: version checks, local model listing, model details, pull progress, native chat/generate bodies, native image input, and diagnostics.

```swift
let provider = OllamaProvider()
let models = try await provider.listModels()
let details = try await provider.showModel("llama3.2")
```

## Native options

```swift
var config = GenerateConfig.default.maxTokens(256)
config[custom: OllamaProvider.self] = OllamaNativeOptions(
    keepAlive: "30m",
    format: .json,
    options: ["num_ctx": 4096]
)
```

## Pull progress

```swift
for try await progress in provider.pullModel("llama3.2") {
    print(progress.status)
}
```

Use `OpenAIProvider` for OpenAI-compatible chat. Use `OllamaProvider` when the app needs local runtime inspection or model-management behavior that the compatibility endpoint does not expose.
