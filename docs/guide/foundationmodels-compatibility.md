# Using Conduit if you know FoundationModels

Conduit includes a FoundationModels-familiar facade for developers who want familiar session and structured-output call sites while still using Conduit providers and runtime control.

This is an ergonomic compatibility layer. It does not replace `Conduit`, `Provider`, `Model`, `Session`, `ChatSession`, provider traits, or Conduit’s capability model.

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

The facade uses `Generable.generationSchema`, `GenerateConfig.responseFormat`, `GeneratedContent(json:)`, and Conduit’s typed decoding path. Invalid structured responses fail with meaningful `AIError.invalidInput` errors.

## Tool reuse

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

`ConduitLanguageModelSession` tracks instructions, prompts, model responses, tool calls, and tool outputs in its `Transcript`.

## Migration notes

- Use `ConduitLanguageModelSession`, not an unqualified `LanguageModelSession`, to avoid conflicts with Apple frameworks.
- Keep Conduit providers as the production integration point for credentials, traits, local runtimes, and capability checks.
- Use typed provider options with `GenerateConfig` for provider-specific request fields.
- Use `ChatSession` directly when you need lower-level streaming metadata, tool-loop controls, or runtime lifecycle hooks.
