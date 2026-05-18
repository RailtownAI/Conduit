// ToolExecutor.swift
// Conduit
//
// Actor for managing tool registration and execution.

import Foundation

// MARK: - Tool Execution Delegate

/// A delegate decision for an intercepted model-generated tool call.
public enum ToolExecutionDecision: Sendable, Equatable {
    /// Execute the registered Conduit tool normally.
    case execute

    /// Stop the tool-call loop without executing this call or continuing generation.
    case stop

    /// Use caller-provided output segments instead of executing the registered tool.
    case provideOutput([Transcript.Segment])
}

/// Observes and controls Conduit tool execution without replacing the tool runtime.
public protocol ToolExecutionDelegate: Sendable {
    func toolExecutor(_ executor: ToolExecutor, didGenerate toolCalls: [Transcript.ToolCall]) async

    func toolExecutor(
        _ executor: ToolExecutor,
        decisionFor toolCall: Transcript.ToolCall
    ) async throws -> ToolExecutionDecision

    func toolExecutor(
        _ executor: ToolExecutor,
        toolCall: Transcript.ToolCall,
        didProduce output: Transcript.ToolOutput
    ) async

    func toolExecutor(
        _ executor: ToolExecutor,
        toolCall: Transcript.ToolCall,
        didFail error: SendableError
    ) async
}

extension ToolExecutionDelegate {
    public func toolExecutor(_ executor: ToolExecutor, didGenerate toolCalls: [Transcript.ToolCall]) async {}

    public func toolExecutor(
        _ executor: ToolExecutor,
        decisionFor toolCall: Transcript.ToolCall
    ) async throws -> ToolExecutionDecision {
        .execute
    }

    public func toolExecutor(
        _ executor: ToolExecutor,
        toolCall: Transcript.ToolCall,
        didProduce output: Transcript.ToolOutput
    ) async {}

    public func toolExecutor(
        _ executor: ToolExecutor,
        toolCall: Transcript.ToolCall,
        didFail error: SendableError
    ) async {}
}

/// Result of delegate-aware tool execution.
public struct ToolExecutionResult: Sendable, Equatable {
    public let outputs: [Transcript.ToolOutput]
    public let shouldContinue: Bool

    public init(outputs: [Transcript.ToolOutput], shouldContinue: Bool) {
        self.outputs = outputs
        self.shouldContinue = shouldContinue
    }
}

// MARK: - ToolExecutor

/// An actor that manages tool registration and execution for LLM interactions.
///
/// `ToolExecutor` provides type-safe tool execution with automatic argument
/// parsing using the `Generable` protocol. It handles the tool call loop,
/// executing tools when the LLM requests them and returning results.
///
/// ## Usage
///
/// ```swift
/// // Define a tool
/// struct WeatherTool: Tool {
///     @Generable
///     struct Arguments {
///         @Guide("City name") let city: String
///     }
///
///     let description = "Get weather for a city"
///
///     func call(arguments: Arguments) async throws -> String {
///         return "Weather in \(arguments.city): 22°C, Sunny"
///     }
/// }
///
/// // Create executor and register tools
/// let executor = ToolExecutor()
/// await executor.register(WeatherTool())
///
/// // Execute a tool call from LLM
/// let result = try await executor.execute(toolCall: toolCall)
/// ```
///
/// ## Thread Safety
///
/// `ToolExecutor` is an actor, ensuring thread-safe access to registered tools
/// and safe concurrent execution.
public actor ToolExecutor {

    /// Strategy for handling tool calls that reference unknown tool names.
    public enum MissingToolPolicy: String, Sendable, Hashable, Codable {
        /// Throw `AIError.invalidInput` when a tool is not registered.
        case throwError

        /// Return a non-fatal tool output text segment describing the missing tool.
        case emitToolOutput
    }

    /// Deterministic retry behavior for tool execution.
    ///
    /// `maxAttempts` includes the initial attempt. For example:
    /// - `maxAttempts = 1`: execute once, no retries.
    /// - `maxAttempts = 2`: up to one retry.
    ///
    /// This policy is deterministic: retries are immediate and do not use delays
    /// or jitter.
    public struct RetryPolicy: Sendable, Hashable, Codable {
        /// Conditions under which failed tool calls are retried.
        public enum Condition: String, Sendable, Hashable, Codable {
            /// Never retry.
            case never

            /// Retry only `AIError` values where `isRetryable == true`.
            case retryableAIErrors

            /// Retry all failures except cancellation.
            case allFailuresExceptCancellation
        }

        /// Maximum number of execution attempts, including the initial attempt.
        public var maxAttempts: Int

        /// Retry condition used after each failed attempt.
        public var condition: Condition

        /// Creates a retry policy.
        ///
        /// Values less than `1` are clamped to `1`.
        ///
        /// - Parameters:
        ///   - maxAttempts: Maximum execution attempts including initial attempt.
        ///   - condition: Error-matching behavior for retries.
        public init(
            maxAttempts: Int = 1,
            condition: Condition = .retryableAIErrors
        ) {
            self.maxAttempts = max(1, maxAttempts)
            self.condition = condition
        }

        /// Execute once, with no retries.
        public static let none = RetryPolicy(maxAttempts: 1, condition: .never)

        /// Retry retryable `AIError` failures up to `maxAttempts`.
        public static func retryableAIErrors(maxAttempts: Int) -> RetryPolicy {
            RetryPolicy(maxAttempts: maxAttempts, condition: .retryableAIErrors)
        }

        /// Retry all non-cancellation failures up to `maxAttempts`.
        public static func allFailures(maxAttempts: Int) -> RetryPolicy {
            RetryPolicy(maxAttempts: maxAttempts, condition: .allFailuresExceptCancellation)
        }

        fileprivate func shouldRetry(after error: any Error, failedAttempt: Int) -> Bool {
            guard failedAttempt < maxAttempts else { return false }

            if error is CancellationError {
                return false
            }

            if let aiError = error as? AIError, case .cancelled = aiError {
                return false
            }

            switch condition {
            case .never:
                return false
            case .retryableAIErrors:
                guard let aiError = error as? AIError else { return false }
                return aiError.isRetryable
            case .allFailuresExceptCancellation:
                return true
            }
        }
    }

    // MARK: - Properties

    /// Registered tools indexed by name.
    private var tools: [String: any Tool] = [:]
    private let missingToolPolicy: MissingToolPolicy

    // MARK: - Initialization

    /// Creates an empty tool executor.
    public init() {
        self.missingToolPolicy = .throwError
    }

    /// Creates an empty tool executor with an explicit missing-tool policy.
    ///
    /// - Parameter missingToolPolicy: Behavior for unknown tool names.
    public init(missingToolPolicy: MissingToolPolicy) {
        self.missingToolPolicy = missingToolPolicy
    }

    /// Creates a tool executor with the given tools.
    ///
    /// - Parameter tools: Tools to register initially.
    public init(tools: [any Tool]) {
        self.missingToolPolicy = .throwError
        for tool in tools {
            self.tools[tool.name] = tool
        }
    }

    /// Creates a tool executor with the given tools and missing-tool policy.
    ///
    /// - Parameters:
    ///   - tools: Tools to register initially.
    ///   - missingToolPolicy: Behavior for unknown tool names.
    public init(tools: [any Tool], missingToolPolicy: MissingToolPolicy) {
        self.missingToolPolicy = missingToolPolicy
        for tool in tools {
            self.tools[tool.name] = tool
        }
    }

    // MARK: - Registration

    /// Registers a tool for execution.
    ///
    /// - Parameter tool: The tool to register.
    /// - Note: If a tool with the same name exists, it will be replaced.
    public func register<T: Tool>(_ tool: T) {
        tools[tool.name] = tool
    }

    /// Registers multiple tools for execution.
    ///
    /// - Parameter toolsToRegister: The tools to register.
    public func register(_ toolsToRegister: [any Tool]) {
        for tool in toolsToRegister {
            tools[tool.name] = tool
        }
    }

    /// Unregisters a tool by name.
    ///
    /// - Parameter name: The name of the tool to unregister.
    /// - Returns: `true` if the tool was found and removed.
    @discardableResult
    public func unregister(name: String) -> Bool {
        tools.removeValue(forKey: name) != nil
    }

    /// Returns all registered tool names.
    public var registeredToolNames: [String] {
        Array(tools.keys)
    }

    /// Returns the schemas for all registered tools.
    ///
    /// Use this to provide tool definitions to the LLM.
    public var toolDefinitions: [Transcript.ToolDefinition] {
        tools.values.map { tool in
            Transcript.ToolDefinition(tool: tool)
        }
    }

    // MARK: - Execution

    /// Executes a tool call from the LLM without retries.
    ///
    /// - Parameter toolCall: The tool call to execute.
    /// - Returns: The result of the tool execution.
    /// - Throws: `AIError.invalidInput` if the tool is not registered,
    ///           or any error from the tool execution.
    public func execute(toolCall: Transcript.ToolCall) async throws -> Transcript.ToolOutput {
        try await execute(toolCall: toolCall, retryPolicy: .none)
    }

    /// Executes a tool call from the LLM with explicit retry behavior.
    ///
    /// - Parameters:
    ///   - toolCall: The tool call to execute.
    ///   - retryPolicy: Retry behavior for failures.
    /// - Returns: The result of the tool execution.
    /// - Throws: `AIError.invalidInput` if the tool is not registered
    ///   (depending on `missingToolPolicy`), or any error from tool execution.
    public func execute(
        toolCall: Transcript.ToolCall,
        retryPolicy: RetryPolicy
    ) async throws -> Transcript.ToolOutput {
        var failedAttempt = 0

        while true {
            try Task.checkCancellation()

            do {
                return try await executeSingleAttempt(toolCall: toolCall)
            } catch {
                failedAttempt += 1
                guard retryPolicy.shouldRetry(after: error, failedAttempt: failedAttempt) else {
                    throw error
                }
            }
        }
    }

    private func executeSingleAttempt(toolCall: Transcript.ToolCall) async throws -> Transcript.ToolOutput {
        guard let tool = tools[toolCall.toolName] else {
            switch missingToolPolicy {
            case .throwError:
                throw AIError.invalidInput("Tool not found: \(toolCall.toolName)")
            case .emitToolOutput:
                return Transcript.ToolOutput(
                    id: toolCall.id,
                    toolName: toolCall.toolName,
                    segments: [.text(.init(content: "Tool not found: \(toolCall.toolName)"))]
                )
            }
        }

        let segments = try await tool.makeOutputSegments(from: toolCall.arguments)
        return Transcript.ToolOutput(
            id: toolCall.id,
            toolName: toolCall.toolName,
            segments: segments
        )
    }

    /// Executes multiple tool calls concurrently.
    ///
    /// - Parameter toolCalls: The tool calls to execute.
    /// - Returns: Results for each tool call, in order.
    /// - Throws: If any tool execution fails or the task is cancelled.
    public func execute(toolCalls: [Transcript.ToolCall]) async throws -> [Transcript.ToolOutput] {
        try await execute(toolCalls: toolCalls, retryPolicy: .none)
    }

    /// Executes multiple tool calls concurrently with explicit retry behavior.
    ///
    /// - Parameters:
    ///   - toolCalls: The tool calls to execute.
    ///   - retryPolicy: Retry behavior for each individual tool call.
    /// - Returns: Results for each tool call, in order.
    /// - Throws: If any tool execution fails or the task is cancelled.
    public func execute(
        toolCalls: [Transcript.ToolCall],
        retryPolicy: RetryPolicy
    ) async throws -> [Transcript.ToolOutput] {
        try Task.checkCancellation()
        guard !toolCalls.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: (Int, Transcript.ToolOutput).self) { group in
            for (index, toolCall) in toolCalls.enumerated() {
                try Task.checkCancellation()

                group.addTask { [self] in
                    let output = try await self.execute(
                        toolCall: toolCall,
                        retryPolicy: retryPolicy
                    )
                    return (index, output)
                }
            }

            var results: [(Int, Transcript.ToolOutput)] = []
            results.reserveCapacity(toolCalls.count)

            for try await result in group {
                results.append(result)
            }

            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    /// Executes multiple tool calls with delegate interception in generated-call order.
    ///
    /// This overload preserves deterministic delegate callback ordering. The existing
    /// non-delegate batch API remains concurrent and unchanged.
    public func execute(
        toolCalls: [Transcript.ToolCall],
        retryPolicy: RetryPolicy,
        delegate: (any ToolExecutionDelegate)?
    ) async throws -> ToolExecutionResult {
        try Task.checkCancellation()
        guard !toolCalls.isEmpty else {
            return ToolExecutionResult(outputs: [], shouldContinue: true)
        }

        guard let delegate else {
            let outputs = try await execute(toolCalls: toolCalls, retryPolicy: retryPolicy)
            return ToolExecutionResult(outputs: outputs, shouldContinue: true)
        }

        await delegate.toolExecutor(self, didGenerate: toolCalls)

        var outputs: [Transcript.ToolOutput] = []
        outputs.reserveCapacity(toolCalls.count)

        for toolCall in toolCalls {
            try Task.checkCancellation()

            let decision = try await delegate.toolExecutor(self, decisionFor: toolCall)

            switch decision {
            case .execute:
                do {
                    let output = try await execute(toolCall: toolCall, retryPolicy: retryPolicy)
                    outputs.append(output)
                    await delegate.toolExecutor(self, toolCall: toolCall, didProduce: output)
                } catch {
                    await delegate.toolExecutor(self, toolCall: toolCall, didFail: SendableError(error))
                    throw error
                }

            case .provideOutput(let segments):
                let output = Transcript.ToolOutput(
                    id: toolCall.id,
                    toolName: toolCall.toolName,
                    segments: segments
                )
                outputs.append(output)
                await delegate.toolExecutor(self, toolCall: toolCall, didProduce: output)

            case .stop:
                return ToolExecutionResult(outputs: outputs, shouldContinue: false)
            }
        }

        return ToolExecutionResult(outputs: outputs, shouldContinue: true)
    }
}
