# GeminiProvider

Use Google’s native Gemini API through a Conduit provider.

## Overview

``GeminiProvider`` is enabled with the `Gemini` package trait. It targets the native Gemini `generateContent` API shape, including `contents`, `systemInstruction`, `generationConfig`, function declarations, inline image data, and JSON structured output.

```swift
let provider = GeminiProvider(apiKey: geminiAPIKey)

let result = try await provider.generate(
    messages: [.system("Be concise."), .user("Explain Swift actors.")],
    model: .gemini("gemini-3-flash-preview"),
    config: .default.maxTokens(300)
)
```

## Structured output

```swift
@Generable
struct Summary {
    let title: String
    let bullets: [String]
}

let result = try await provider.generate(
    messages: [.user("Summarize this document.")],
    model: .gemini("gemini-3-flash-preview"),
    config: .default.responseFormat(.jsonSchema(name: "summary", schema: Summary.generationSchema))
)
```

Conduit maps the schema into Gemini `generationConfig.responseSchema` and sets `responseMimeType` to `application/json`.

## Typed Gemini options

Use typed custom options for Gemini-only fields:

```swift
var config = GenerateConfig.default
config[custom: GeminiProvider.self] = GeminiOptions(
    thinkingConfig: ["thinkingLevel": "low"],
    toolConfig: ["includeServerSideToolInvocations": true],
    serverTools: [["googleSearch": [:]]]
)
```

Provider-specific fields remain provider-owned and do not expand global ``GenerateConfig``.

## Multimodal input

Gemini image input is represented with Conduit `Message.Content.parts`:

```swift
let image = Message.ImageContent(base64Data: encodedPNG, mimeType: "image/png")
let message = Message(role: .user, content: .parts([
    .text("Describe this image."),
    .image(image)
]))
```

``GeminiProvider`` serializes images as Gemini `inlineData`.
