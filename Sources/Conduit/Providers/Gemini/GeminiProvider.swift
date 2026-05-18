// GeminiProvider.swift
// Conduit

#if CONDUIT_TRAIT_GEMINI
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GeminiConfiguration: Sendable, Hashable, Codable {
    public var apiKey: String
    public var baseURL: URL
    public var timeout: TimeInterval
    public var defaultHeaders: [String: String]

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        timeout: TimeInterval = 60,
        defaultHeaders: [String: String] = [:]
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.timeout = max(0, timeout)
        self.defaultHeaders = defaultHeaders
    }
}

public struct GeminiOptions: Sendable, Codable, Equatable {
    public var thinkingConfig: [String: JSONValue]?
    public var toolConfig: [String: JSONValue]?
    public var serverTools: [[String: JSONValue]]
    public var extraBody: [String: JSONValue]

    public init(
        thinkingConfig: [String: JSONValue]? = nil,
        toolConfig: [String: JSONValue]? = nil,
        serverTools: [[String: JSONValue]] = [],
        extraBody: [String: JSONValue] = [:]
    ) {
        self.thinkingConfig = thinkingConfig
        self.toolConfig = toolConfig
        self.serverTools = serverTools
        self.extraBody = extraBody
    }
}

public actor GeminiProvider: AIProvider, TextGenerator {
    public typealias Response = GenerationResult
    public typealias StreamChunk = GenerationChunk
    public typealias ModelID = ModelIdentifier

    public nonisolated let configuration: GeminiConfiguration
    private let session: URLSession

    public init(configuration: GeminiConfiguration) {
        self.configuration = configuration
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.timeout
        sessionConfig.timeoutIntervalForResource = configuration.timeout * 2
        self.session = URLSession(configuration: sessionConfig)
    }

    public init(apiKey: String) {
        self.init(configuration: GeminiConfiguration(apiKey: apiKey))
    }

    public nonisolated var isAvailable: Bool { !configuration.apiKey.isEmpty }
    public nonisolated var availabilityStatus: ProviderAvailability {
        isAvailable ? .available : .unavailable(.apiKeyMissing)
    }

    public func generate(_ prompt: String, model: ModelIdentifier, config: GenerateConfig) async throws -> String {
        try await generate(messages: [.user(prompt)], model: model, config: config).text
    }

    public func generate(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig
    ) async throws -> GenerationResult {
        let body = buildRequestBody(messages: messages, model: model, config: config)
        let data = try JSONSerialization.data(withJSONObject: body)
        let (responseData, response) = try await session.data(for: makeRequest(model: model, method: "generateContent", body: data))
        try validate(response: response, data: responseData)
        return try parseGenerationResponse(data: responseData)
    }

    public nonisolated func stream(
        _ prompt: String,
        model: ModelIdentifier,
        config: GenerateConfig
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await chunk in streamWithMetadata(messages: [.user(prompt)], model: model, config: config) {
                        if !chunk.text.isEmpty {
                            continuation.yield(chunk.text)
                        }
                    }
                    continuation.finish()
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
                    try await self.performStreamingGeneration(
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

    private func performStreamingGeneration(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig,
        continuation: AsyncThrowingStream<GenerationChunk, Error>.Continuation
    ) async throws {
        let body = buildRequestBody(messages: messages, model: model, config: config)
        let data = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.asyncBytes(for: makeStreamRequest(model: model, body: data))
        try validate(response: response, data: Data())

        var parser = ServerSentEventParser()
        for try await line in bytes.lines {
            for event in parser.ingestLine(line) {
                guard let chunk = try decodeStreamEvent(event.data) else { continue }
                continuation.yield(chunk)
            }
        }
        for event in parser.finish() {
            guard let chunk = try decodeStreamEvent(event.data) else { continue }
            continuation.yield(chunk)
        }
        continuation.finish()
    }

    public nonisolated func buildRequestBody(
        messages: [Message],
        model: ModelIdentifier,
        config: GenerateConfig
    ) -> [String: Any] {
        var contents: [[String: Any]] = []
        var systemParts: [[String: Any]] = []

        for message in messages {
            let parts = serializeContentParts(for: message)
            if message.role == .system {
                systemParts.append(contentsOf: parts)
            } else {
                contents.append([
                    "role": message.role == .assistant ? "model" : "user",
                    "parts": parts
                ])
            }
        }

        var generationConfig: [String: Any] = [
            "temperature": config.temperature,
            "topP": config.topP
        ]
        if let maxTokens = config.maxTokens {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if !config.stopSequences.isEmpty {
            generationConfig["stopSequences"] = config.stopSequences
        }
        if let responseFormat = config.responseFormat {
            generationConfig["responseMimeType"] = "application/json"
            if case .jsonSchema(_, let schema) = responseFormat {
                generationConfig["responseSchema"] = schema.toJSONSchema()
            }
        }

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": generationConfig
        ]

        if !systemParts.isEmpty {
            body["systemInstruction"] = ["parts": systemParts]
        }

        if !config.tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": config.tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters.toJSONSchema()
                    ]
                }
            ]]
        }

        if let options: GeminiOptions = config[custom: GeminiProvider.self] {
            if let thinkingConfig = options.thinkingConfig {
                generationConfig["thinkingConfig"] = thinkingConfig.mapValues(\.anyValue)
                body["generationConfig"] = generationConfig
            }
            if let toolConfig = options.toolConfig {
                body["toolConfig"] = toolConfig.mapValues(\.anyValue)
            }
            if !options.serverTools.isEmpty {
                var tools = body["tools"] as? [[String: Any]] ?? []
                tools.append(contentsOf: options.serverTools.map { $0.mapValues(\.anyValue) })
                body["tools"] = tools
            }
            for (key, value) in options.extraBody where !Self.reservedBodyKeys.contains(key) {
                body[key] = value.anyValue
            }
        }

        return body
    }

    public nonisolated func parseGenerationResponse(data: Data) throws -> GenerationResult {
        let json = try jsonObject(data)
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? 500
            let message = error["message"] as? String
            throw AIError.serverError(statusCode: code, message: message)
        }

        let candidates = json["candidates"] as? [[String: Any]] ?? []
        guard let first = candidates.first else {
            throw AIError.generationFailed(underlying: SendableError(localizedDescription: "Gemini response did not include candidates"))
        }
        let parts = ((first["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []

        var text = ""
        var toolCalls: [Transcript.ToolCall] = []
        for part in parts {
            if let partText = part["text"] as? String {
                text += partText
            }
            if let functionCall = part["functionCall"] as? [String: Any],
               let name = functionCall["name"] as? String {
                let args = (functionCall["args"] as? [String: Any]) ?? [:]
                let argsData = try JSONSerialization.data(withJSONObject: args)
                let argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                toolCalls.append(try Transcript.ToolCall(
                    id: functionCall["id"] as? String ?? UUID().uuidString,
                    toolName: name,
                    argumentsJSON: argsString,
                    metadata: preservedToolCallMetadata(from: part, functionCall: functionCall)
                ))
            }
        }

        if (first["finishReason"] as? String)?.uppercased() == "MALFORMED_FUNCTION_CALL" {
            throw AIError.generationFailed(underlying: SendableError(localizedDescription: "Gemini returned a malformed function call"))
        }

        let finishReason = toolCalls.isEmpty ? mapFinishReason(first["finishReason"] as? String) : .toolCalls
        return GenerationResult(
            text: toolCalls.isEmpty ? text : "",
            tokenCount: 0,
            generationTime: 0,
            tokensPerSecond: 0,
            finishReason: finishReason,
            toolCalls: toolCalls
        )
    }

    public nonisolated func decodeStreamEvent(_ data: String) throws -> GenerationChunk? {
        guard let payload = data.data(using: .utf8), !payload.isEmpty else {
            return nil
        }
        let json = try jsonObject(payload)
        let rawFinishReason = (json["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String
        let result = try parseGenerationResponse(data: payload)
        let hasTerminalReason = rawFinishReason != nil || !result.toolCalls.isEmpty
        return GenerationChunk(
            text: result.text,
            tokenCount: result.tokenCount,
            isComplete: hasTerminalReason,
            finishReason: hasTerminalReason ? result.finishReason : nil,
            completedToolCalls: result.toolCalls.isEmpty ? nil : result.toolCalls
        )
    }

    private nonisolated func makeRequest(model: ModelIdentifier, method: String, body: Data) -> URLRequest {
        let url = configuration.baseURL
            .appendingPathComponent("models")
            .appendingPathComponent(model.rawValue + ":\(method)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (header, value) in configuration.defaultHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        return request
    }

    nonisolated func makeStreamRequest(model: ModelIdentifier, body: Data) -> URLRequest {
        let url = configuration.baseURL
            .appendingPathComponent("models")
            .appendingPathComponent(model.rawValue + ":streamGenerateContent")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "alt", value: "sse")]

        var request = URLRequest(url: components?.url ?? url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = configuration.timeout
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (header, value) in configuration.defaultHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        return request
    }

    private nonisolated func serializeContentParts(for message: Message) -> [[String: Any]] {
        if message.role == .tool {
            return [serializeFunctionResponse(for: message)]
        }

        var parts = serializeParts(message.content)
        if message.role == .assistant,
           let toolCalls = message.metadata?.toolCalls,
           !toolCalls.isEmpty {
            parts.append(contentsOf: toolCalls.map(serializeFunctionCall))
        }
        return parts
    }

    private nonisolated func mapFinishReason(_ reason: String?) -> FinishReason {
        switch reason?.uppercased() {
        case nil, "", "STOP":
            return .stop
        case "MAX_TOKENS":
            return .maxTokens
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII":
            return .contentFilter
        case "MALFORMED_FUNCTION_CALL":
            return .stop
        default:
            return .stop
        }
    }

    private nonisolated func serializeParts(_ content: Message.Content) -> [[String: Any]] {
        switch content {
        case .text(let text):
            guard !text.isEmpty else { return [] }
            return [["text": text]]
        case .parts(let parts):
            return parts.compactMap { part in
                switch part {
                case .text(let text):
                    guard !text.isEmpty else { return nil }
                    return ["text": text]
                case .image(let image):
                    return [
                        "inlineData": [
                            "mimeType": image.mimeType,
                            "data": image.base64Data
                        ]
                    ]
                case .audio(let audio):
                    return [
                        "inlineData": [
                            "mimeType": audio.format.mimeType,
                            "data": audio.base64Data
                        ]
                    ]
                }
            }
        }
    }

    private nonisolated func serializeFunctionCall(_ toolCall: Transcript.ToolCall) -> [String: Any] {
        var functionCall: [String: Any] = [
            "id": toolCall.id,
            "name": toolCall.toolName
        ]
        if let argsData = toolCall.argumentsString.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
            functionCall["args"] = args
        } else {
            functionCall["args"] = [:]
        }

        var part: [String: Any] = ["functionCall": functionCall]
        for (key, value) in toolCall.metadata {
            part[key] = value.anyValue
        }
        return part
    }

    private nonisolated func preservedToolCallMetadata(
        from part: [String: Any],
        functionCall: [String: Any]
    ) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [:]
        for key in ["thoughtSignature", "thought_signature"] {
            if let value = part[key] ?? functionCall[key],
               let jsonValue = try? JSONValue(AnyCodable(value)) {
                metadata[key] = jsonValue
            }
        }
        return metadata
    }

    private nonisolated func serializeFunctionResponse(for message: Message) -> [String: Any] {
        var response: [String: Any] = [
            "name": message.metadata?.custom?["tool_name"] ?? "tool",
            "response": ["result": message.content.textValue]
        ]
        if let id = message.metadata?.custom?["tool_call_id"] {
            response["id"] = id
        }
        return ["functionResponse": response]
    }

    private nonisolated func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? jsonObject(data)["error"] as? [String: Any])?["message"] as? String
            throw AIError.serverError(statusCode: http.statusCode, message: message)
        }
    }

    private nonisolated func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.generationFailed(underlying: SendableError(localizedDescription: "Gemini returned invalid JSON"))
        }
        return json
    }

    private nonisolated static let reservedBodyKeys: Set<String> = [
        "contents",
        "generationConfig",
        "systemInstruction"
    ]
}

private extension Message.AudioFormat {
    var mimeType: String {
        switch self {
        case .wav: return "audio/wav"
        case .mp3: return "audio/mp3"
        case .aiff: return "audio/aiff"
        case .aac: return "audio/aac"
        case .m4a: return "audio/mp4"
        case .flac: return "audio/flac"
        case .ogg: return "audio/ogg"
        }
    }
}

#endif
