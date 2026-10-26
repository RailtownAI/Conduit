// AnthropicToolUseHistoryEncodingTests.swift
// Conduit
//
// Tests that prior tool calls replayed in conversation history reach the
// Anthropic Messages API as plain JSON `input` objects.
//
// Regression: `tool_use.input` used to be encoded from `GeneratedContent`
// directly, which emits Conduit's internal tree
// (`{"kind": {"type": "structure", "properties": ..., "orderedKeys": [...]}}`).
// The model read its own earlier calls back as malformed and kept repeating
// them until `maxToolCallRounds` was exceeded.

#if CONDUIT_TRAIT_ANTHROPIC
import Testing
import Foundation
@testable import Conduit

@Suite("Anthropic tool_use history encoding")
struct AnthropicToolUseHistoryEncodingTests {
    private let model: ModelIdentifier = .anthropic("claude-sonnet-4-6")

    private func provider() -> AnthropicProvider {
        AnthropicProvider(configuration: .standard(apiKey: "sk-test-only"))
    }

    /// Builds a request whose history holds one completed tool round and returns
    /// the encoded body as a JSON object.
    private func encodedBody(argumentsJSON: String) async throws -> [String: Any] {
        let call = try Transcript.ToolCall(
            id: "toolu_01",
            toolName: "calculator",
            argumentsJSON: argumentsJSON
        )
        let messages: [Message] = [
            Message(role: .user, content: .text("What is 2 + 2?")),
            .assistant("", toolCalls: [call]),
            Message(
                role: .tool,
                content: .text("4"),
                metadata: MessageMetadata(custom: ["tool_call_id": "toolu_01"])
            )
        ]
        let request = try await provider().buildRequestBody(
            messages: messages,
            model: model,
            config: .default
        )
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func toolUseBlock(in body: [String: Any]) throws -> [String: Any] {
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let blocks = try #require(assistant["content"] as? [[String: Any]])
        return try #require(blocks.first { $0["type"] as? String == "tool_use" })
    }

    @Test("Replayed tool_use input is the plain JSON object the model sent")
    func replayedInputIsPlainJSON() async throws {
        let body = try await encodedBody(argumentsJSON: #"{"prompt":"x","n":2}"#)
        let block = try toolUseBlock(in: body)
        let input = try #require(block["input"] as? [String: Any])

        #expect(Set(input.keys) == ["prompt", "n"])
        #expect(input["prompt"] as? String == "x")
        #expect((input["n"] as? NSNumber)?.intValue == 2)
        #expect(input["kind"] == nil)
        #expect(input["orderedKeys"] == nil)
    }

    @Test("Nested arguments keep their shape")
    func nestedArgumentsKeepShape() async throws {
        let body = try await encodedBody(
            argumentsJSON: #"{"filter":{"tags":["a","b"],"exact":true}}"#
        )
        let block = try toolUseBlock(in: body)
        let input = try #require(block["input"] as? [String: Any])
        let filter = try #require(input["filter"] as? [String: Any])

        #expect(filter["tags"] as? [String] == ["a", "b"])
        #expect(filter["exact"] as? Bool == true)
    }

    @Test("Tool result still follows with the matching tool_use_id")
    func toolResultMatchesToolUse() async throws {
        let body = try await encodedBody(argumentsJSON: #"{"prompt":"x"}"#)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let last = try #require(messages.last)
        let blocks = try #require(last["content"] as? [[String: Any]])
        let result = try #require(blocks.first)

        #expect(last["role"] as? String == "user")
        #expect(result["type"] as? String == "tool_result")
        #expect(result["tool_use_id"] as? String == "toolu_01")
    }
}
#endif
