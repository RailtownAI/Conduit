// OpenResponsesProvider.swift
// Conduit

#if CONDUIT_TRAIT_OPENAI || CONDUIT_TRAIT_OPENROUTER
import Foundation

/// First-class provider wrapper for OpenAI Responses-compatible generation endpoints.
public actor OpenResponsesProvider: AIProvider, TextGenerator {
    public typealias Response = GenerationResult
    public typealias StreamChunk = GenerationChunk
    public typealias ModelID = ModelIdentifier

    public nonisolated let configuration: OpenAIConfiguration
    private nonisolated let provider: OpenAIProvider

    public init(configuration: OpenAIConfiguration) {
        var responsesConfiguration = configuration
        responsesConfiguration.apiVariant = .responses
        self.configuration = responsesConfiguration
        self.provider = OpenAIProvider(configuration: responsesConfiguration)
    }

    public init(apiKey: String, baseURL: URL? = nil) {
        self.init(configuration: .openResponses(apiKey: apiKey, baseURL: baseURL))
    }

    public nonisolated var isAvailable: Bool {
        get async { await provider.isAvailable }
    }

    public nonisolated var availabilityStatus: ProviderAvailability {
        get async { await provider.availabilityStatus }
    }

    public func generate(_ prompt: String, model: ModelIdentifier, config: GenerateConfig) async throws -> String {
        try await provider.generate(prompt, model: model, config: config)
    }

    public func generate(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig
    ) async throws -> GenerationResult {
        try await provider.generate(messages: messages, model: model, config: config)
    }

    public nonisolated func stream(
        _ prompt: String,
        model: ModelIdentifier,
        config: GenerateConfig
    ) -> AsyncThrowingStream<String, Error> {
        provider.stream(prompt, model: model, config: config)
    }

    public nonisolated func stream(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig
    ) -> AsyncThrowingStream<GenerationChunk, Error> {
        provider.stream(messages: messages, model: model, config: config)
    }

    public nonisolated func streamWithMetadata(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig
    ) -> AsyncThrowingStream<GenerationChunk, Error> {
        provider.streamWithMetadata(messages: messages, model: model, config: config)
    }

    public func cancelGeneration() async {
        await provider.cancelGeneration()
    }

    nonisolated func buildRequestBody(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig,
        stream: Bool,
        variant: OpenAIAPIVariant = .responses
    ) -> [String: Any] {
        provider.buildRequestBody(messages: messages, model: model, config: config, stream: stream, variant: variant)
    }
}

/// Typed request options for OpenAI Responses-compatible providers.
public struct OpenResponsesOptions: Sendable, Codable, Equatable {
    public var toolChoice: JSONValue?
    public var allowedTools: [String]?
    public var reasoning: JSONValue?
    public var verbosity: String?
    public var truncation: String?
    public var metadata: [String: String]?
    public var extraBody: [String: JSONValue]

    public init(
        toolChoice: JSONValue? = nil,
        allowedTools: [String]? = nil,
        reasoning: JSONValue? = nil,
        verbosity: String? = nil,
        truncation: String? = nil,
        metadata: [String: String]? = nil,
        extraBody: [String: JSONValue] = [:]
    ) {
        self.toolChoice = toolChoice
        self.allowedTools = allowedTools
        self.reasoning = reasoning
        self.verbosity = verbosity
        self.truncation = truncation
        self.metadata = metadata
        self.extraBody = extraBody
    }
}

extension OpenAIConfiguration {
    public static func openResponses(
        apiKey: String,
        baseURL: URL? = nil
    ) -> OpenAIConfiguration {
        OpenAIConfiguration(
            endpoint: baseURL.map(OpenAIEndpoint.custom) ?? .openAI,
            authentication: .bearer(apiKey),
            apiVariant: .responses
        )
    }
}

#endif
