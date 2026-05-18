#if CONDUIT_TRAIT_GEMINI
import Foundation
import Testing
@testable import Conduit

@Generable
private struct GeminiTestProfile {
    let name: String
}

@Generable
private struct GeminiWeatherArgs {
    let city: String
}

@Suite("GeminiProvider")
struct GeminiProviderTests {
    @Test("request body includes contents, system instruction, and generation config")
    func requestBodyConstruction() {
        let provider = GeminiProvider(apiKey: "test-key")
        let body = provider.buildRequestBody(
            messages: [.system("Be concise"), .user("Hello")],
            model: .gemini("gemini-3-flash-preview"),
            config: .default.maxTokens(99)
        )

        #expect((body["systemInstruction"] as? [String: Any]) != nil)
        let contents = body["contents"] as? [[String: Any]]
        #expect(contents?.count == 1)
        #expect((body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == 99)
    }

    @Test("structured output config maps to Gemini JSON response schema")
    func structuredOutputConfig() {
        let provider = GeminiProvider(apiKey: "test-key")
        let body = provider.buildRequestBody(
            messages: [.user("Profile")],
            model: .gemini("gemini-3-flash-preview"),
            config: .default.responseFormat(.jsonSchema(name: "profile", schema: GeminiTestProfile.generationSchema))
        )

        let generationConfig = body["generationConfig"] as? [String: Any]
        #expect(generationConfig?["responseMimeType"] as? String == "application/json")
        #expect(generationConfig?["responseSchema"] != nil)
    }

    @Test("tools and typed Gemini options merge into request")
    func toolAndTypedOptions() {
        let provider = GeminiProvider(apiKey: "test-key")
        let tool = Transcript.ToolDefinition(
            name: "weather",
            description: "Get weather",
            parameters: GeminiWeatherArgs.generationSchema
        )
        var config = GenerateConfig.default.tools([tool])
        config[custom: GeminiProvider.self] = GeminiOptions(
            thinkingConfig: ["thinkingLevel": "low"],
            toolConfig: ["includeServerSideToolInvocations": true],
            serverTools: [["googleSearch": [:]]]
        )

        let body = provider.buildRequestBody(
            messages: [.user("Weather?")],
            model: .gemini("gemini-3-flash-preview"),
            config: config
        )

        let tools = body["tools"] as? [[String: Any]]
        #expect(tools?.count == 2)
        #expect((body["toolConfig"] as? [String: Any])?["includeServerSideToolInvocations"] as? Bool == true)
        #expect(((body["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == "low")
    }

    @Test("multimodal image input serializes inline data")
    func multimodalImageInput() {
        let provider = GeminiProvider(apiKey: "test-key")
        let image = Message.ImageContent(base64Data: "abc123", mimeType: "image/png")
        let body = provider.buildRequestBody(
            messages: [Message(role: .user, content: .parts([.text("Describe"), .image(image)]))],
            model: .gemini("gemini-3-flash-preview"),
            config: .default
        )

        let contents = body["contents"] as? [[String: Any]]
        let parts = contents?.first?["parts"] as? [[String: Any]]
        let inlineData = parts?.last?["inlineData"] as? [String: Any]
        #expect(inlineData?["mimeType"] as? String == "image/png")
        #expect(inlineData?["data"] as? String == "abc123")
    }

    @Test("response parsing extracts text and tool calls")
    func responseParsing() throws {
        let provider = GeminiProvider(apiKey: "test-key")
        let data = Data("""
        {
          "candidates": [{
            "content": {
              "parts": [
                { "text": "Hello" },
                { "functionCall": { "id": "call_1", "name": "weather", "args": { "city": "SF" } }, "thoughtSignature": "sig-123" }
              ]
            }
          }]
        }
        """.utf8)

        let result = try provider.parseGenerationResponse(data: data)

        #expect(result.finishReason == .toolCalls)
        #expect(result.toolCalls.first?.toolName == "weather")
        #expect(result.toolCalls.first?.id == "call_1")
        #expect(result.toolCalls.first?.metadata["thoughtSignature"]?.stringValue == "sig-123")
    }

    @Test("tool call history serializes function calls and function responses")
    func toolCallHistorySerialization() throws {
        let provider = GeminiProvider(apiKey: "test-key")
        let call = try Transcript.ToolCall(
            id: "call_123",
            toolName: "weather",
            argumentsJSON: #"{"city":"SF"}"#,
            metadata: ["thoughtSignature": "sig-abc"]
        )

        let body = provider.buildRequestBody(
            messages: [
                .user("Weather?"),
                .assistant("", toolCalls: [call]),
                .toolOutput(call: call, content: "Foggy")
            ],
            model: .gemini("gemini-3-flash-preview"),
            config: .default
        )

        let contents = try #require(body["contents"] as? [[String: Any]])
        let assistantParts = try #require(contents[1]["parts"] as? [[String: Any]])
        let functionCallPart = try #require(assistantParts.first)
        let functionCall = try #require(functionCallPart["functionCall"] as? [String: Any])
        #expect(functionCall["id"] as? String == "call_123")
        #expect(functionCall["name"] as? String == "weather")
        #expect(functionCallPart["thoughtSignature"] as? String == "sig-abc")

        let toolParts = try #require(contents[2]["parts"] as? [[String: Any]])
        let functionResponse = try #require(toolParts.first?["functionResponse"] as? [String: Any])
        #expect(functionResponse["id"] as? String == "call_123")
        #expect(functionResponse["name"] as? String == "weather")
        #expect((functionResponse["response"] as? [String: Any])?["result"] as? String == "Foggy")
    }

    @Test("stream event parsing returns chunks")
    func streamEventParsing() {
        let provider = GeminiProvider(apiKey: "test-key")
        let chunk = provider.decodeStreamEvent("""
        {"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}
        """)

        #expect(chunk?.text == "Hi")
    }

    @Test("streaming request targets Gemini SSE endpoint")
    func streamingRequestTargetsSSEEndpoint() throws {
        let provider = GeminiProvider(apiKey: "test-key")
        let request = provider.makeStreamRequest(
            model: .gemini("gemini-3-flash-preview"),
            body: Data(#"{"contents":[]}"#.utf8)
        )

        let url = try #require(request.url?.absoluteString)
        #expect(request.httpMethod == "POST")
        #expect(url.contains(":streamGenerateContent"))
        #expect(url.contains("alt=sse"))
    }

    @Test("API error maps to AIError.serverError")
    func apiErrorMapping() {
        let provider = GeminiProvider(apiKey: "test-key")
        let data = Data(#"{"error":{"code":429,"message":"rate limited"}}"#.utf8)

        #expect(throws: AIError.self) {
            _ = try provider.parseGenerationResponse(data: data)
        }
    }
}
#endif
