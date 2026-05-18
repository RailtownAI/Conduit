#if CONDUIT_TRAIT_OPENAI
import Foundation
import Testing
@testable import Conduit

private struct OpenAIOnlyOptions: Codable, Sendable, Equatable {
    var mode: String
}

@Suite("OpenResponsesProvider")
struct OpenResponsesProviderTests {
    @Test("factory configures Responses variant and custom base URL")
    func factoryConfiguresResponsesVariant() {
        let provider = OpenResponsesProvider(configuration: .openResponses(
            apiKey: "sk-test",
            baseURL: URL(string: "https://example.test/v1")!
        ))

        #expect(provider.configuration.apiVariant == .responses)
        #expect(provider.configuration.endpoint.responsesURL.absoluteString == "https://example.test/v1/responses")
    }

    @Test("typed options merge into Responses request body")
    func typedOptionsMergeIntoBody() throws {
        let provider = OpenResponsesProvider(configuration: .openResponses(apiKey: "sk-test"))
        var config = GenerateConfig.default
        config[custom: OpenResponsesProvider.self] = OpenResponsesOptions(
            toolChoice: .string("required"),
            allowedTools: ["search"],
            reasoning: ["effort": "high"],
            verbosity: "low",
            truncation: "auto",
            metadata: ["trace_id": "abc"],
            extraBody: ["store": false]
        )

        let body = provider.buildRequestBody(
            messages: [.user("Hello")],
            model: .gpt4o,
            config: config,
            stream: false,
            variant: .responses
        )

        let toolChoice = try #require(body["tool_choice"] as? [String: Any])
        #expect(toolChoice["type"] as? String == "allowed_tools")
        #expect(toolChoice["mode"] as? String == "required")
        let allowedTools = try #require(toolChoice["tools"] as? [[String: Any]])
        #expect(allowedTools.first?["type"] as? String == "function")
        #expect(allowedTools.first?["name"] as? String == "search")
        #expect(body["allowed_tools"] == nil)
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect((body["text"] as? [String: Any])?["verbosity"] as? String == "low")
        #expect(body["truncation"] as? String == "auto")
        #expect((body["metadata"] as? [String: Any])?["trace_id"] as? String == "abc")
        #expect(body["store"] as? Bool == false)
    }

    @Test("Open Responses custom options do not collide with OpenAIProvider options")
    func customOptionsAreIsolatedFromOpenAIProvider() {
        var config = GenerateConfig.default
        config[custom: OpenResponsesProvider.self] = OpenResponsesOptions(verbosity: "low")
        config[custom: OpenAIProvider.self] = OpenAIOnlyOptions(mode: "chat")

        let responsesOptions: OpenResponsesOptions? = config[custom: OpenResponsesProvider.self]
        let openAIOptions: OpenAIOnlyOptions? = config[custom: OpenAIProvider.self]

        #expect(responsesOptions?.verbosity == "low")
        #expect(openAIOptions == OpenAIOnlyOptions(mode: "chat"))
    }
}
#endif
