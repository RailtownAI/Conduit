// OllamaProvider.swift
// Conduit

#if CONDUIT_TRAIT_OLLAMA
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OllamaNativeConfiguration: Sendable, Hashable, Codable {
    public var baseURL: URL
    public var timeout: TimeInterval
    public var defaultHeaders: [String: String]

    public init(
        baseURL: URL = URL(string: "http://localhost:11434/api")!,
        timeout: TimeInterval = 60,
        defaultHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.timeout = max(0, timeout)
        self.defaultHeaders = defaultHeaders
    }
}

public enum OllamaResponseFormat: Sendable, Codable, Equatable {
    case json
    case schema([String: JSONValue])
}

public struct OllamaNativeOptions: Sendable, Codable, Equatable {
    public var keepAlive: String?
    public var raw: Bool?
    public var format: OllamaResponseFormat?
    public var options: [String: JSONValue]
    public var extraBody: [String: JSONValue]

    public init(
        keepAlive: String? = nil,
        raw: Bool? = nil,
        format: OllamaResponseFormat? = nil,
        options: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:]
    ) {
        self.keepAlive = keepAlive
        self.raw = raw
        self.format = format
        self.options = options
        self.extraBody = extraBody
    }
}

public struct OllamaModelDetails: Sendable, Hashable, Codable {
    public let parentModel: String?
    public let format: String?
    public let family: String?
    public let families: [String]?
    public let parameterSize: String?
    public let quantizationLevel: String?
}

public struct OllamaModelSummary: Sendable, Hashable, Codable {
    public let name: String
    public let model: String?
    public let modifiedAt: String?
    public let size: Int64?
    public let digest: String?
    public let details: OllamaModelDetails?
}

public struct OllamaModelShow: Sendable, Hashable, Codable {
    public let modelfile: String?
    public let parameters: String?
    public let template: String?
    public let details: OllamaModelDetails?
    public let modelInfo: [String: JSONValue]
    public let capabilities: [String]

    public init(
        modelfile: String? = nil,
        parameters: String? = nil,
        template: String? = nil,
        details: OllamaModelDetails? = nil,
        modelInfo: [String: JSONValue] = [:],
        capabilities: [String] = []
    ) {
        self.modelfile = modelfile
        self.parameters = parameters
        self.template = template
        self.details = details
        self.modelInfo = modelInfo
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case modelfile
        case parameters
        case template
        case details
        case modelInfo
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelfile = try container.decodeIfPresent(String.self, forKey: .modelfile)
        self.parameters = try container.decodeIfPresent(String.self, forKey: .parameters)
        self.template = try container.decodeIfPresent(String.self, forKey: .template)
        self.details = try container.decodeIfPresent(OllamaModelDetails.self, forKey: .details)
        self.modelInfo = try container.decodeIfPresent([String: JSONValue].self, forKey: .modelInfo) ?? [:]
        self.capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }
}

public struct OllamaPullProgress: Sendable, Hashable, Codable {
    public let status: String
    public let digest: String?
    public let total: Int64?
    public let completed: Int64?

    public var fractionCompleted: Double? {
        guard let total, total > 0, let completed else { return nil }
        return Double(completed) / Double(total)
    }
}

public struct OllamaVersion: Sendable, Hashable, Codable {
    public let version: String
}

public struct OllamaDiagnostics: Sendable, Hashable, Codable {
    public let version: OllamaVersion?
    public let models: [OllamaModelSummary]
    public let runningModels: [OllamaModelSummary]
}

public actor OllamaProvider: AIProvider, TextGenerator {
    public typealias Response = GenerationResult
    public typealias StreamChunk = GenerationChunk
    public typealias ModelID = ModelIdentifier

    public nonisolated let configuration: OllamaNativeConfiguration
    private let session: URLSession

    public init(configuration: OllamaNativeConfiguration = .init()) {
        self.configuration = configuration
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.timeout
        sessionConfig.timeoutIntervalForResource = configuration.timeout * 2
        self.session = URLSession(configuration: sessionConfig)
    }

    public nonisolated var isAvailable: Bool { true }
    public nonisolated var availabilityStatus: ProviderAvailability { .available }

    public func generate(_ prompt: String, model: ModelIdentifier, config: GenerateConfig) async throws -> String {
        try await generate(messages: [.user(prompt)], model: model, config: config).text
    }

    public func generate(messages: [Message], model: ModelIdentifier, config: GenerateConfig) async throws -> GenerationResult {
        let body = buildChatBody(messages: messages, model: model, config: config, stream: false)
        let data = try JSONSerialization.data(withJSONObject: body)
        let (responseData, response) = try await session.data(for: makeRequest(path: "chat", body: data))
        try validate(response: response, data: responseData)
        return try parseChatResponse(responseData)
    }

    public nonisolated func stream(_ prompt: String, model: ModelIdentifier, config: GenerateConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.performGenerateStream(
                        prompt: prompt,
                        model: model,
                        config: config,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public nonisolated func stream(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig
    ) -> AsyncThrowingStream<GenerationChunk, Error> {
        streamWithMetadata(messages: messages, model: model, config: config)
    }

    public nonisolated func streamWithMetadata(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig
    ) -> AsyncThrowingStream<GenerationChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.performChatStream(
                        messages: messages,
                        model: model,
                        config: config,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func cancelGeneration() async {}

    public func version() async throws -> OllamaVersion {
        let (data, response) = try await session.data(for: makeRequest(path: "version", method: "GET"))
        try validate(response: response, data: data)
        return try decode(OllamaVersion.self, from: data)
    }

    public func listModels() async throws -> [OllamaModelSummary] {
        let (data, response) = try await session.data(for: makeRequest(path: "tags", method: "GET"))
        try validate(response: response, data: data)
        return try parseModelList(data)
    }

    public func showModel(_ model: String, verbose: Bool = false) async throws -> OllamaModelShow {
        let data = try JSONSerialization.data(withJSONObject: ["model": model, "verbose": verbose])
        let (responseData, response) = try await session.data(for: makeRequest(path: "show", body: data))
        try validate(response: response, data: responseData)
        return try parseModelShow(responseData)
    }

    public func pullModel(_ model: String) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.performPullStream(model: model, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func performGenerateStream(
        prompt: String,
        model: ModelIdentifier,
        config: GenerateConfig,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let request = makeStreamingGenerateRequest(prompt: prompt, model: model, config: config)
        let (bytes, response) = try await session.asyncBytes(for: request)
        try validate(response: response, data: Data())
        for try await line in bytes.lines where !line.isEmpty {
            let result = try parseGenerateResponse(Data(line.utf8))
            if !result.text.isEmpty {
                continuation.yield(result.text)
            }
        }
        continuation.finish()
    }

    private func performChatStream(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig,
        continuation: AsyncThrowingStream<GenerationChunk, Error>.Continuation
    ) async throws {
        let body = buildChatBody(messages: messages, model: model, config: config, stream: true)
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = makeRequest(path: "chat", body: data)
        let (bytes, response) = try await session.asyncBytes(for: request)
        try validate(response: response, data: Data())
        for try await line in bytes.lines where !line.isEmpty {
            continuation.yield(try parseChatStreamChunk(Data(line.utf8)))
        }
        continuation.finish()
    }

    private func performPullStream(
        model: String,
        continuation: AsyncThrowingStream<OllamaPullProgress, Error>.Continuation
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let request = makeRequest(path: "pull", body: data)
        let (bytes, response) = try await session.asyncBytes(for: request)
        try validate(response: response, data: Data())
        for try await line in bytes.lines where !line.isEmpty {
            continuation.yield(try parsePullProgress(Data(line.utf8)))
        }
        continuation.finish()
    }

    public func diagnostics() async throws -> OllamaDiagnostics {
        let currentVersion = try? await version()
        let localModels = try await listModels()
        return OllamaDiagnostics(version: currentVersion, models: localModels, runningModels: [])
    }

    public nonisolated func buildGenerateBody(
        prompt: Message,
        model: ModelIdentifier,
        config: GenerateConfig,
        stream: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "prompt": prompt.content.textValue,
            "stream": stream
        ]
        let images = imagePayloads(from: prompt.content)
        if !images.isEmpty {
            body["images"] = images
        }
        applyOptions(from: config, to: &body)
        return body
    }

    public nonisolated func buildChatBody(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig,
        stream: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "messages": messages.map(serializeChatMessage),
            "stream": stream
        ]
        if !config.tools.isEmpty && config.toolChoice != .none {
            body["tools"] = config.tools.map(serializeToolDefinition)
        }
        applyOptions(from: config, to: &body)
        return body
    }

    public nonisolated func parseGenerateResponse(_ data: Data) throws -> GenerationResult {
        let json = try jsonObject(data)
        try throwIfOllamaError(json)
        let text = json["response"] as? String ?? ""
        return generationResult(text: text, json: json)
    }

    public nonisolated func parseChatResponse(_ data: Data) throws -> GenerationResult {
        let json = try jsonObject(data)
        try throwIfOllamaError(json)
        let message = (json["message"] as? [String: Any]) ?? [:]
        let text = message["content"] as? String ?? ""
        let toolCalls = parseToolCalls(from: message)
        return generationResult(text: text, json: json, toolCalls: toolCalls)
    }

    public nonisolated func parseChatStreamChunk(_ data: Data) throws -> GenerationChunk {
        let json = try jsonObject(data)
        try throwIfOllamaError(json)
        let message = (json["message"] as? [String: Any]) ?? [:]
        let text = message["content"] as? String ?? ""
        let toolCalls = parseToolCalls(from: message)
        let completionTokens = json["eval_count"] as? Int ?? 0
        let promptTokens = json["prompt_eval_count"] as? Int ?? 0
        let isDone = json["done"] as? Bool ?? false
        return GenerationChunk(
            text: text,
            tokenCount: completionTokens,
            isComplete: isDone,
            finishReason: isDone ? (toolCalls.isEmpty ? mapDoneReason(json["done_reason"] as? String) : .toolCalls) : nil,
            usage: isDone ? UsageStats(promptTokens: promptTokens, completionTokens: completionTokens) : nil,
            completedToolCalls: toolCalls.isEmpty ? nil : toolCalls
        )
    }

    public nonisolated func parseModelList(_ data: Data) throws -> [OllamaModelSummary] {
        struct Response: Decodable { let models: [OllamaModelSummary] }
        return try decode(Response.self, from: data).models
    }

    public nonisolated func parseModelShow(_ data: Data) throws -> OllamaModelShow {
        try decode(OllamaModelShow.self, from: data)
    }

    public nonisolated func parsePullProgress(_ data: Data) throws -> OllamaPullProgress {
        let json = try jsonObject(data)
        try throwIfOllamaError(json)
        return try decode(OllamaPullProgress.self, from: data)
    }

    private nonisolated func applyOptions(from config: GenerateConfig, to body: inout [String: Any]) {
        var options: [String: Any] = [
            "temperature": config.temperature,
            "top_p": config.topP
        ]
        if let maxTokens = config.maxTokens {
            options["num_predict"] = maxTokens
        }
        if !config.stopSequences.isEmpty {
            options["stop"] = config.stopSequences
        }

        if let nativeOptions: OllamaNativeOptions = config[custom: OllamaProvider.self] {
            if let keepAlive = nativeOptions.keepAlive {
                body["keep_alive"] = keepAlive
            }
            if let raw = nativeOptions.raw {
                body["raw"] = raw
            }
            if let format = nativeOptions.format {
                switch format {
                case .json:
                    body["format"] = "json"
                case .schema(let schema):
                    body["format"] = schema.mapValues(\.anyValue)
                }
            }
            for (key, value) in nativeOptions.options {
                options[key] = value.anyValue
            }
            for (key, value) in nativeOptions.extraBody where !Self.reservedBodyKeys.contains(key) {
                body[key] = value.anyValue
            }
        }

        body["options"] = options
    }

    private nonisolated func makeStreamingGenerateRequest(prompt: String, model: ModelIdentifier, config: GenerateConfig) -> URLRequest {
        let body = buildGenerateBody(prompt: .user(prompt), model: model, config: config, stream: true)
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return makeRequest(path: "generate", body: data)
    }

    nonisolated func makeRequest(path: String, method: String = "POST", body: Data? = nil) -> URLRequest {
        let url = configuration.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (header, value) in configuration.defaultHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        return request
    }

    private nonisolated func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? jsonObject(data)["error"] as? String)
            throw AIError.serverError(statusCode: http.statusCode, message: message)
        }
    }

    private nonisolated func generationResult(
        text: String,
        json: [String: Any],
        toolCalls: [Transcript.ToolCall] = []
    ) -> GenerationResult {
        let completionTokens = json["eval_count"] as? Int ?? 0
        let promptTokens = json["prompt_eval_count"] as? Int ?? 0
        let finishReason = toolCalls.isEmpty ? mapDoneReason(json["done_reason"] as? String) : .toolCalls
        return GenerationResult(
            text: toolCalls.isEmpty ? text : "",
            tokenCount: completionTokens,
            generationTime: 0,
            tokensPerSecond: 0,
            finishReason: finishReason,
            usage: UsageStats(promptTokens: promptTokens, completionTokens: completionTokens),
            toolCalls: toolCalls
        )
    }

    private nonisolated func serializeChatMessage(_ message: Message) -> [String: Any] {
        var serialized: [String: Any] = [
            "role": message.role.rawValue,
            "content": message.content.textValue
        ]
        let images = imagePayloads(from: message.content)
        if !images.isEmpty {
            serialized["images"] = images
        }
        if message.role == .assistant,
           let toolCalls = message.metadata?.toolCalls,
           !toolCalls.isEmpty {
            serialized["tool_calls"] = toolCalls.enumerated().map { index, toolCall in
                serializeToolCall(toolCall, index: index)
            }
        }
        if message.role == .tool,
           let toolName = message.metadata?.custom?["tool_name"] {
            serialized["tool_name"] = toolName
        }
        return serialized
    }

    private nonisolated func serializeToolDefinition(_ tool: Transcript.ToolDefinition) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parameters.toJSONSchema()
            ]
        ]
    }

    private nonisolated func serializeToolCall(_ toolCall: Transcript.ToolCall, index: Int) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "index": index,
                "name": toolCall.toolName,
                "arguments": decodeToolArguments(toolCall.argumentsString)
            ]
        ]
    }

    private nonisolated func parseToolCalls(from message: [String: Any]) -> [Transcript.ToolCall] {
        guard let rawToolCalls = message["tool_calls"] as? [[String: Any]] else { return [] }
        return rawToolCalls.enumerated().compactMap { index, rawCall in
            let function = rawCall["function"] as? [String: Any] ?? rawCall
            guard let name = function["name"] as? String else { return nil }
            let id = (rawCall["id"] as? String)
                ?? (rawCall["call_id"] as? String)
                ?? "ollama_tool_\(index)"
            let arguments = encodeToolArguments(function["arguments"])
            return try? Transcript.ToolCall(id: id, toolName: name, argumentsJSON: arguments)
        }
    }

    private nonisolated func encodeToolArguments(_ arguments: Any?) -> String {
        if let string = arguments as? String {
            return string.isEmpty ? "{}" : string
        }
        if let object = arguments,
           JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{}"
    }

    private nonisolated func decodeToolArguments(_ argumentsString: String) -> Any {
        guard let data = argumentsString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object) else {
            return [:]
        }
        return object
    }

    private nonisolated func mapDoneReason(_ reason: String?) -> FinishReason {
        switch reason?.lowercased() {
        case nil, "", "stop":
            return .stop
        case "length", "max_tokens", "num_predict":
            return .maxTokens
        case "tool_calls", "tool_call":
            return .toolCalls
        default:
            return .stop
        }
    }

    private nonisolated func imagePayloads(from content: Message.Content) -> [String] {
        guard case .parts(let parts) = content else { return [] }
        return parts.compactMap { part in
            if case .image(let image) = part {
                return image.base64Data
            }
            return nil
        }
    }

    private nonisolated func throwIfOllamaError(_ json: [String: Any]) throws {
        if let message = json["error"] as? String {
            throw AIError.serverError(statusCode: 500, message: message)
        }
    }

    private nonisolated func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.generationFailed(underlying: SendableError(localizedDescription: "Ollama returned invalid JSON"))
        }
        return json
    }

    private nonisolated func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    private nonisolated static let reservedBodyKeys: Set<String> = [
        "model",
        "prompt",
        "messages",
        "stream",
        "images",
        "options",
        "keep_alive",
        "raw",
        "format"
    ]
}

#endif
