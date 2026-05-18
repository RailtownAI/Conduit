# OllamaProvider

Use native Ollama APIs for local runtime management.

## Overview

Conduit supports Ollama in two layers:

- ``OpenAIProvider`` with `.ollama()` remains the simple OpenAI-compatible text-generation path.
- ``OllamaProvider`` is enabled with the `Ollama` trait and exposes native local-runtime operations such as version checks, local model listing, model details, pull progress, native chat/generate bodies, multimodal image input, and diagnostics.

```swift
let provider = OllamaProvider()
let models = try await provider.listModels()
let details = try await provider.showModel("llama3.2")
```

## Native options

Use typed custom options for fields specific to Ollama’s native API:

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

Use ``OpenAIProvider`` for the broad OpenAI-compatible chat surface. Use ``OllamaProvider`` when the app needs local runtime inspection or model-management behavior that the OpenAI-compatible endpoint does not expose.
