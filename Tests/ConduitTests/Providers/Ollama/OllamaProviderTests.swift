#if CONDUIT_TRAIT_OLLAMA
import Foundation
import Testing
@testable import Conduit

@Generable
private struct OllamaToolArgs {
    let city: String
}

@Suite("OllamaProvider")
struct OllamaProviderTests {
    @Test("native generate body includes prompt, stream flag, images, and typed options")
    func nativeGenerateBodyConstruction() {
        let provider = OllamaProvider(configuration: .init(baseURL: URL(string: "http://localhost:11434/api")!))
        var config = GenerateConfig.default.maxTokens(64)
        config[custom: OllamaProvider.self] = OllamaNativeOptions(
            keepAlive: "10m",
            raw: true,
            format: .json,
            options: ["num_ctx": 4096],
            extraBody: ["think": .bool(true)]
        )

        let body = provider.buildGenerateBody(
            prompt: Message(role: .user, content: .parts([
                .text("Describe"),
                .image(.init(base64Data: "abc123", mimeType: "image/png"))
            ])),
            model: .openAI("llama3.2-vision"),
            config: config,
            stream: true
        )

        #expect(body["model"] as? String == "llama3.2-vision")
        #expect(body["stream"] as? Bool == true)
        #expect(body["images"] as? [String] == ["abc123"])
        #expect(body["keep_alive"] as? String == "10m")
        #expect(body["raw"] as? Bool == true)
        #expect(body["format"] as? String == "json")
        #expect(body["think"] as? Bool == true)
        #expect((body["options"] as? [String: Any])?["num_predict"] as? Int == 64)
        #expect((body["options"] as? [String: Any])?["num_ctx"] as? Int == 4096)
    }

    @Test("chat body preserves roles, native images, and custom options")
    func nativeChatBodyConstruction() {
        let provider = OllamaProvider(configuration: .init(baseURL: URL(string: "http://localhost:11434/api")!))
        var config = GenerateConfig.default.temperature(0.2)
        config[custom: OllamaProvider.self] = OllamaNativeOptions(
            keepAlive: "30m",
            options: ["num_gpu": 0]
        )

        let body = provider.buildChatBody(
            messages: [
                .system("Be brief"),
                Message(role: .user, content: .parts([
                    .text("What is this?"),
                    .image(.init(base64Data: "img", mimeType: "image/jpeg"))
                ]))
            ],
            model: .openAI("llama3.2-vision"),
            config: config,
            stream: false
        )

        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.count == 2)
        #expect(messages?.first?["role"] as? String == "system")
        #expect(messages?.last?["images"] as? [String] == ["img"])
        #expect(body["keep_alive"] as? String == "30m")
        #expect((body["options"] as? [String: Any])?["temperature"] as? Float == 0.2)
        #expect((body["options"] as? [String: Any])?["num_gpu"] as? Int == 0)
    }

    @Test("chat body includes configured tool definitions")
    func nativeChatBodyIncludesTools() throws {
        let provider = OllamaProvider(configuration: .init(baseURL: URL(string: "http://localhost:11434/api")!))
        let tool = Transcript.ToolDefinition(
            name: "weather",
            description: "Get weather",
            parameters: OllamaToolArgs.generationSchema
        )

        let body = provider.buildChatBody(
            messages: [.user("Weather?")],
            model: .openAI("llama3.2"),
            config: .default.tools([tool]),
            stream: false
        )

        let tools = try #require(body["tools"] as? [[String: Any]])
        let first = try #require(tools.first)
        let function = try #require(first["function"] as? [String: Any])
        #expect(first["type"] as? String == "function")
        #expect(function["name"] as? String == "weather")
        #expect(function["description"] as? String == "Get weather")
        #expect(function["parameters"] != nil)
    }

    @Test("chat body preserves assistant tool calls and tool outputs")
    func nativeChatBodyPreservesToolHistory() throws {
        let provider = OllamaProvider(configuration: .init(baseURL: URL(string: "http://localhost:11434/api")!))
        let call = try Transcript.ToolCall(
            id: "call-weather",
            toolName: "weather",
            argumentsJSON: #"{"city":"SF"}"#
        )

        let body = provider.buildChatBody(
            messages: [
                .user("Weather?"),
                .assistant("", toolCalls: [call]),
                .toolOutput(call: call, content: "Clear")
            ],
            model: .openAI("llama3.2"),
            config: .default,
            stream: false
        )

        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = messages[1]
        let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
        let function = try #require(toolCalls.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "weather")
        #expect((function["arguments"] as? [String: Any])?["city"] as? String == "SF")
        #expect(messages[2]["role"] as? String == "tool")
        #expect(messages[2]["tool_name"] as? String == "weather")
    }

    @Test("native model list and show responses parse diagnostics")
    func modelMetadataParsing() throws {
        let provider = OllamaProvider(configuration: .init(baseURL: URL(string: "http://localhost:11434/api")!))

        let list = try provider.parseModelList(Data("""
        {
          "models": [
            {
              "name": "llama3.2:latest",
              "model": "llama3.2:latest",
              "modified_at": "2026-05-01T12:00:00Z",
              "size": 2019393189,
              "digest": "sha256:abc",
              "details": { "family": "llama", "parameter_size": "3B", "quantization_level": "Q4_K_M" }
            }
          ]
        }
        """.utf8))

        #expect(list.first?.name == "llama3.2:latest")
        #expect(list.first?.details?.family == "llama")

        let show = try provider.parseModelShow(Data("""
        {
          "modelfile": "FROM llama3.2",
          "parameters": "temperature 0.7",
          "template": "{{ .Prompt }}",
          "details": { "family": "llama", "parameter_size": "3B" },
          "model_info": { "general.architecture": "llama" }
        }
        """.utf8))

        #expect(show.details?.parameterSize == "3B")
        #expect(show.modelInfo["general.architecture"]?.stringValue == "llama")
    }

    @Test("pull progress and API errors parse")
    func pullProgressAndErrorParsing() throws {
        let provider = OllamaProvider(configuration: .init(baseURL: URL(string: "http://localhost:11434/api")!))

        let progress = try provider.parsePullProgress(Data("""
        {"status":"downloading","digest":"sha256:abc","total":100,"completed":25}
        """.utf8))
        #expect(progress.status == "downloading")
        #expect(progress.fractionCompleted == 0.25)

        #expect(throws: AIError.self) {
            _ = try provider.parseGenerateResponse(Data(#"{"error":"model not found"}"#.utf8))
        }
    }

    @Test("intermediate streaming chat chunks do not expose terminal finish reason")
    func intermediateStreamingChatChunkHasNoFinishReason() throws {
        let provider = OllamaProvider(configuration: .init(baseURL: URL(string: "http://localhost:11434/api")!))

        let chunk = try provider.parseChatStreamChunk(Data("""
        {"message":{"content":"hel"},"done":false}
        """.utf8))

        #expect(chunk.text == "hel")
        #expect(chunk.isComplete == false)
        #expect(chunk.finishReason == nil)
    }

    @Test("final streaming chat chunks preserve done reason")
    func finalStreamingChatChunkPreservesDoneReason() throws {
        let provider = OllamaProvider(configuration: .init(baseURL: URL(string: "http://localhost:11434/api")!))

        let chunk = try provider.parseChatStreamChunk(Data("""
        {"message":{"content":""},"done":true,"done_reason":"length","eval_count":16,"prompt_eval_count":4}
        """.utf8))

        #expect(chunk.isComplete == true)
        #expect(chunk.finishReason == .maxTokens)
        #expect(chunk.usage?.completionTokens == 16)
    }

    @Test("chat responses parse native tool calls")
    func chatResponseParsesToolCalls() throws {
        let provider = OllamaProvider(configuration: .init(baseURL: URL(string: "http://localhost:11434/api")!))

        let result = try provider.parseChatResponse(Data("""
        {
          "message": {
            "role": "assistant",
            "content": "",
            "tool_calls": [
              {
                "function": {
                  "name": "weather",
                  "arguments": { "city": "SF" }
                }
              }
            ]
          },
          "done": true,
          "done_reason": "stop"
        }
        """.utf8))

        #expect(result.finishReason == .toolCalls)
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls.first?.toolName == "weather")
        #expect(result.toolCalls.first?.argumentsString.contains(#""city":"SF""#) == true)
    }

    @Test("streaming chat chunks expose completed native tool calls")
    func streamChunkParsesToolCalls() throws {
        let provider = OllamaProvider(configuration: .init(baseURL: URL(string: "http://localhost:11434/api")!))

        let chunk = try provider.parseChatStreamChunk(Data("""
        {
          "message": {
            "role": "assistant",
            "content": "",
            "tool_calls": [
              {
                "function": {
                  "name": "weather",
                  "arguments": { "city": "SF" }
                }
              }
            ]
          },
          "done": true
        }
        """.utf8))

        #expect(chunk.isComplete == true)
        #expect(chunk.finishReason == .toolCalls)
        #expect(chunk.completedToolCalls?.first?.toolName == "weather")
    }

    @Test("requests carry configured timeout for streaming and pull paths")
    func requestTimeoutUsesConfiguration() {
        let provider = OllamaProvider(configuration: .init(
            baseURL: URL(string: "http://localhost:11434/api")!,
            timeout: 12
        ))

        #expect(provider.makeRequest(path: "chat").timeoutInterval == 12)
        #expect(provider.makeRequest(path: "pull").timeoutInterval == 12)
        #expect(provider.makeRequest(path: "generate").timeoutInterval == 12)
    }
}
#endif
