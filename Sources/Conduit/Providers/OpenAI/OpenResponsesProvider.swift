// OpenResponsesProvider.swift
// Conduit

#if CONDUIT_TRAIT_OPENAI || CONDUIT_TRAIT_OPENROUTER
import Foundation

/// First-class name for OpenAI Responses-compatible generation endpoints.
public typealias OpenResponsesProvider = OpenAIProvider

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
