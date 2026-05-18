import Testing
@testable import ConduitAdvanced

@Generable
private struct CompatibilityProfile: Equatable {
    @Guide(description: "Display name")
    let name: String

    @Guide(description: "Age in years", .minimum(0))
    let age: Int
}

private actor CompatibilityProvider: AIProvider, @preconcurrency TextGenerator {
    typealias Response = GenerationResult
    typealias StreamChunk = GenerationChunk
    typealias ModelID = ModelIdentifier

    private var queuedResults: [GenerationResult]
    private var streamedChunks: [String]
    private(set) var receivedMessages: [[Message]] = []

    init(results: [GenerationResult], streamedChunks: [String] = []) {
        self.queuedResults = results
        self.streamedChunks = streamedChunks
    }

    var isAvailable: Bool { true }
    var availabilityStatus: ProviderAvailability { .available }

    func generate(messages: [Message], model: ModelIdentifier, config: GenerateConfig) async throws -> GenerationResult {
        receivedMessages.append(messages)
        guard !queuedResults.isEmpty else { return .text("ok") }
        return queuedResults.removeFirst()
    }

    nonisolated func generate(_ prompt: String, model: ModelIdentifier, config: GenerateConfig) async throws -> String {
        let result = try await generate(messages: [.user(prompt)], model: model, config: config)
        return result.text
    }

    nonisolated func stream(_ prompt: String, model: ModelIdentifier, config: GenerateConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await chunk in streamWithMetadata(messages: [.user(prompt)], model: model, config: config) {
                        continuation.yield(chunk.text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    nonisolated func stream(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig
    ) -> AsyncThrowingStream<GenerationChunk, Error> {
        streamWithMetadata(messages: messages, model: model, config: config)
    }

    nonisolated func streamWithMetadata(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig
    ) -> AsyncThrowingStream<GenerationChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(messages: messages)
                let chunks = await self.currentStreamedChunks()
                for (index, chunk) in chunks.enumerated() {
                    continuation.yield(GenerationChunk(
                        text: chunk,
                        tokenCount: 0,
                        isComplete: index == chunks.count - 1,
                        finishReason: index == chunks.count - 1 ? .stop : nil
                    ))
                }
                continuation.finish()
            }
        }
    }

    func cancelGeneration() async {}

    private func record(messages: [Message]) {
        receivedMessages.append(messages)
    }

    private func currentStreamedChunks() -> [String] {
        streamedChunks
    }
}

private struct CompatibilityWeatherTool: Tool {
    let name = "weather"
    let description = "Returns weather for a city."

    @Generable
    struct Arguments {
        let city: String
    }

    func call(arguments: Arguments) async throws -> GeneratedContent {
        try GeneratedContent(json: #"{"summary":"Clear in \#(arguments.city)"}"#)
    }
}

@Suite("ConduitLanguageModelSession")
struct ConduitLanguageModelSessionTests {
    @Test("respond(to:) delegates through existing Conduit provider and updates transcript")
    func respondDelegatesAndUpdatesTranscript() async throws {
        let provider = CompatibilityProvider(results: [.text("Hello")])
        let model = ConduitLanguageModel(
            provider: .custom(provider, mapModel: { _ in .openAI("test-model") }),
            model: .openAI("test-model")
        )
        let session = try ConduitLanguageModelSession(
            model: model,
            instructions: Instructions("Be concise.")
        )

        let response = try await session.respond(to: "Say hello")

        #expect(response.content == "Hello")
        #expect(session.transcript.count == 3)
        #expect(session.transcript.contains { if case .instructions = $0 { true } else { false } })
        #expect(session.transcript.contains { if case .prompt = $0 { true } else { false } })
        #expect(session.transcript.contains { if case .response = $0 { true } else { false } })
    }

    @Test("respond(to:generating:) decodes Generable values and reports decode failures")
    func structuredRespondDecodesAndReportsFailures() async throws {
        let provider = CompatibilityProvider(results: [
            .text(#"{"name":"Ava","age":31}"#),
            .text(#"{"name":true}"#)
        ])
        let model = ConduitLanguageModel(
            provider: .custom(provider, mapModel: { _ in .openAI("test-model") }),
            model: .openAI("test-model")
        )
        let session = try ConduitLanguageModelSession(model: model)

        let response = try await session.respond(to: Prompt("Make a profile"), generating: CompatibilityProfile.self)

        #expect(response.content.name == "Ava")
        #expect(response.content.age == 31)

        await #expect(throws: AIError.self) {
            _ = try await session.respond(to: "Make a broken profile", generating: CompatibilityProfile.self)
        }
    }

    @Test("respond(to:) executes tools and mirrors tool calls and outputs in transcript")
    func respondExecutesToolsAndUpdatesTranscript() async throws {
        let toolCall = try Transcript.ToolCall(
            id: "call-1",
            toolName: "weather",
            argumentsJSON: #"{"city":"SF"}"#
        )
        let provider = CompatibilityProvider(results: [
            GenerationResult(
                text: "",
                tokenCount: 0,
                generationTime: 0,
                tokensPerSecond: 0,
                finishReason: .toolCalls,
                toolCalls: [toolCall]
            ),
            .text("It is clear.")
        ])
        let model = ConduitLanguageModel(
            provider: .custom(provider, mapModel: { _ in .openAI("test-model") }),
            model: .openAI("test-model")
        )
        let session = try ConduitLanguageModelSession(
            model: model,
            tools: [CompatibilityWeatherTool()]
        )

        let response = try await session.respond(to: "Check weather")

        #expect(response.content == "It is clear.")
        #expect(session.transcript.contains { if case .toolCalls = $0 { true } else { false } })
        #expect(session.transcript.contains { if case .toolOutput = $0 { true } else { false } })
        #expect(session.transcript.contains { if case .response = $0 { true } else { false } })
    }

    @Test("streamResponse(to:generating:) yields partial Generable snapshots")
    func structuredStreamYieldsSnapshots() async throws {
        let provider = CompatibilityProvider(
            results: [],
            streamedChunks: [#"{"name":"Ava""#, #","age":31}"#]
        )
        let model = ConduitLanguageModel(
            provider: .custom(provider, mapModel: { _ in .openAI("test-model") }),
            model: .openAI("test-model")
        )
        let session = try ConduitLanguageModelSession(model: model)

        let stream = session.streamResponse(to: "Stream a profile", generating: CompatibilityProfile.self)
        var last: ConduitLanguageModelSession.ResponseStream<CompatibilityProfile>.Snapshot?
        for try await snapshot in stream {
            last = snapshot
        }

        #expect(last?.content.name == "Ava")
        #expect(last?.content.age == 31)
        #expect(session.transcript.count == 2)
    }
}
