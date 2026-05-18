# Using Conduit if you know FoundationModels

Use Conduit’s FoundationModels-familiar facade when you want familiar call sites with Conduit’s provider/runtime underneath.

## Overview

``ConduitLanguageModel`` and ``ConduitLanguageModelSession`` mirror the shape FoundationModels developers expect: create a model, create a session with instructions and tools, then call `respond(to:)`, `respond(to:generating:)`, `streamResponse(to:)`, or `streamResponse(to:generating:)`.

This is an ergonomic compatibility layer. It delegates to Conduit providers, sessions, `GenerateConfig`, tool execution, and typed structured output. It does not replace ``Conduit``, ``Provider``, ``Model``, ``Session``, ``ChatSession``, or the provider capability model.

## Side-by-side

FoundationModels-style:

```swift
let model = ConduitLanguageModel(
    provider: .openAI(apiKey: apiKey),
    model: .openAI("gpt-4.1-mini")
)

let session = try ConduitLanguageModelSession(
    model: model,
    tools: [WeatherTool()],
    instructions: Instructions("Be concise.")
)

let response = try await session.respond(to: "Weather in San Francisco?")
```

Conduit-style:

```swift
let conduit = Conduit(.openAI(apiKey: apiKey))
let session = try conduit.session(model: .openAI("gpt-4.1-mini")) {
    $0.instructions("Be concise.")
    $0.tools { WeatherTool() }
}

let response = try await session.run("Weather in San Francisco?")
```

## Structured output

Existing `@Generable` and `@Guide` models work with the facade:

```swift
@Generable
struct TripSummary {
    @Guide(description: "Short destination name")
    let destination: String

    @Guide(description: "Three concise highlights")
    let highlights: [String]
}

let output = try await session.respond(
    to: "Plan a weekend in Kyoto.",
    generating: TripSummary.self
)

print(output.content.destination)
```

Decode failures surface as ``AIError/invalidInput(_:)`` with the raw JSON context where possible.

## Tool reuse

Tools remain Conduit tools. Nested `Arguments` types continue to synthesize schemas through `@Generable`.

```swift
struct WeatherTool: Tool {
    let name = "weather"
    let description = "Look up current weather."

    @Generable
    struct Arguments {
        let city: String
    }

    func call(arguments: Arguments) async throws -> GeneratedContent {
        try GeneratedContent(json: #"{"summary":"Clear"}"#)
    }
}
```

``ConduitLanguageModelSession`` records prompts, responses, tool calls, tool outputs, and instructions in its ``Transcript`` view.

## Migration notes

- Use `ConduitLanguageModelSession`, not an unqualified `LanguageModelSession`, to avoid conflicts with Apple frameworks.
- Keep using Conduit providers for production setup, capability checks, credentials, local runtimes, and provider-specific options.
- Use typed provider options with `GenerateConfig` for provider-specific request details instead of adding global config fields.
- Drop down to ``ChatSession`` when you need lower-level control over the tool loop, streaming metadata, or runtime lifecycle.
