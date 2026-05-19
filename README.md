<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-dark.svg">
    <img src="docs/assets/banner-light.svg" alt="Conduit Banner" width="100%">
  </picture>
</p>

<p align="center">
  <a href="https://swift.org">
    <img src="https://img.shields.io/badge/Swift-6.2-F05138.svg?style=flat&logo=swift" alt="Swift 6.2">
  </a>
  <a href="https://developer.apple.com">
    <img src="https://img.shields.io/badge/Platforms-iOS%2017+%20|%20macOS%2014+%20|%20visionOS%201+%20|%20Linux-007AFF.svg?style=flat" alt="Platforms">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-MIT-green.svg?style=flat" alt="License">
  </a>
  <a href="https://github.com/christopherkarani/Conduit/stargazers">
    <img src="https://img.shields.io/github/stars/christopherkarani/Conduit?style=flat" alt="Stars">
  </a>
</p>

<p align="center">
  <b>Conduit</b> — type-safe LLM inference for Swift.
  <br>
  One API. Every provider. Compile-time schemas. Native SwiftUI.
</p>

<p align="center">
  <a href="README.md">English</a> |
  <a href="locales/README.es.md">Español</a> |
  <a href="locales/README.ja.md">日本語</a> |
  <a href="locales/README.zh-CN.md">中文</a>
</p>

---

## What Conduit gives you

- **Compile-time validated schemas** — Define the shape of LLM output with `@Generable` and catch mismatches before you ship.
- **One API for every provider** — Claude, GPT-4o, Gemini, Ollama, MLX, CoreML, llama.cpp. Swap providers without rewriting your app.
- **Native tool calling** — Expose Swift functions to models with strongly-typed arguments. The tool loop is handled for you.
- **Streaming + SwiftUI ready** — `AsyncSequence` streaming and an `@Observable` `ChatSession` that drops into a `View`.
- **Fast local inference** — First-class MLX support tuned for Apple Silicon.

---

## Installation

### Swift Package Manager

```bash
swift package add --url https://github.com/christopherkarani/Conduit --from 0.3.0
```

Or add it in Xcode: **File → Add Package Dependencies** → `https://github.com/christopherkarani/Conduit`

### Enable Provider Traits

Conduit uses Swift 6 package traits to keep compile times fast and binaries small. **You must enable the traits for the providers you want to use.**

```swift
// Package.swift
.package(
    url: "https://github.com/christopherkarani/Conduit",
    from: "0.3.0",
    traits: ["Anthropic", "OpenAI", "MLX"] // ← pick your providers
)
```

**Available traits:** `Anthropic`, `OpenAI`, `OpenRouter`, `Gemini`, `Kimi`, `MiniMax`, `MLX`, `CoreML`, `Ollama`, `Llama`, `HuggingFaceHub`

> **Linux or server-side?** Skip `MLX`. Cloud providers work out of the box. For local inference on Linux, use the `Ollama` trait.

---

## Start Here

### 1. Generate text in 4 lines

```swift
import Conduit

let provider = AnthropicProvider(apiKey: "sk-ant-...")
let response = try await provider.generate(
    "Explain the benefits of Swift Actors",
    model: .claudeSonnet45,
    config: .default.maxTokens(300)
)
print(response)
```

### 2. Get structured, type-safe output

This is Conduit's superpower. Define a Swift struct, attach `@Generable`, and the LLM returns a validated instance.

```swift
import Conduit

@Generable
struct MovieReview {
    let title: String
    let rating: Int
    @Guide("One-paragraph summary")
    let summary: String
    let pros: [String]
    let cons: [String]
}

let provider = AnthropicProvider(apiKey: "sk-ant-...")
let result = try await provider.generate(
    messages: Messages { Message.user("Review the movie Inception") },
    model: .claudeSonnet45,
    config: .default.responseFormat(.jsonSchema(MovieReview.generationSchema))
)

let review = try MovieReview(GeneratedContent(json: result.text))
print(review.rating) // 9
```

### 3. Let models call your Swift functions

```swift
@Generable
struct WeatherArgs {
    @Guide("City name") let city: String
    @Guide("Unit", .anyOf(["celsius", "fahrenheit"])) let unit: String
}

struct WeatherTool: Tool {
    let name = "get_weather"
    let description = "Get current weather"
    func call(arguments: WeatherArgs) async throws -> String {
        return "72°F and sunny in \(arguments.city)"
    }
}

let result = try await provider.generate(
    messages: Messages { Message.user("What's the weather in Tokyo?") },
    model: .claudeSonnet45,
    config: .default.tools([WeatherTool()])
)
```

### 4. Swap providers without changing your logic

```swift
// Cloud
let anthropic = AnthropicProvider(apiKey: "sk-ant-...")

// Local Apple Silicon (MLX)
let mlx = MLXProvider()

// Local via Ollama
let ollama = OpenAIProvider(ollamaHost: "localhost", port: 11434)

// Same generate() API on every provider.
```

### 5. Drop a chat session into SwiftUI

```swift
import SwiftUI
import Conduit

struct ChatView: View {
    @State private var session = ChatSession(
        provider: AnthropicProvider(apiKey: "sk-ant-..."),
        model: .claudeSonnet45
    )
    @State private var input = ""

    var body: some View {
        VStack {
            ScrollView { /* messages */ }
            HStack {
                TextField("Message", text: $input)
                Button("Send") {
                    Task {
                        let reply = try await session.send(input)
                        input = ""
                        // append reply to UI
                    }
                }
            }
        }
    }
}
```

---

## Documentation

- [**Getting Started**](docs/guide/getting-started.md) — Installation, traits, and your first generation.
- [**Structured Output**](docs/guide/structured-output.md) — `@Generable`, `@Guide`, and compile-time schemas.
- [**Tool Calling**](docs/guide/tool-calling.md) — Native Swift tools with automatic tool loops.
- [**Streaming**](docs/guide/streaming.md) — Real-time `AsyncSequence` streaming.
- [**Chat Session**](docs/guide/chat-session.md) — `ChatSession`, history, and SwiftUI integration.
- [**Architecture**](docs/guide/architecture.md) — How Conduit is put together.

---

## Performance

Conduit is tuned for Apple Silicon and local model throughput.

| Hardware | Model | Quantization | Tokens/sec |
|---|---|---|---|
| M3 Max | Llama 3.1 8B | 4-bit | ~85 |
| M2 Max | Llama 3.1 8B | 4-bit | ~62 |
| M1 Pro | Llama 3.2 1B | 4-bit | ~120 |

---

## License

Conduit is released under the **MIT License**. See [LICENSE](LICENSE).
