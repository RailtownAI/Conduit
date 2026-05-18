import Testing
@testable import ConduitAdvanced

private actor RecordingToolDelegate: ToolExecutionDelegate {
    enum Event: Equatable {
        case generated([String])
        case decision(String)
        case output(String, String)
        case failure(String, String)
    }

    private var decisions: [String: ToolExecutionDecision]
    private var events: [Event] = []

    init(decisions: [String: ToolExecutionDecision] = [:]) {
        self.decisions = decisions
    }

    var recordedEvents: [Event] { events }

    func toolExecutor(_ executor: ToolExecutor, didGenerate toolCalls: [Transcript.ToolCall]) async {
        events.append(.generated(toolCalls.map(\.id)))
    }

    func toolExecutor(
        _ executor: ToolExecutor,
        decisionFor toolCall: Transcript.ToolCall
    ) async throws -> ToolExecutionDecision {
        events.append(.decision(toolCall.id))
        return decisions[toolCall.id] ?? .execute
    }

    func toolExecutor(
        _ executor: ToolExecutor,
        toolCall: Transcript.ToolCall,
        didProduce output: Transcript.ToolOutput
    ) async {
        events.append(.output(toolCall.id, output.text))
    }

    func toolExecutor(
        _ executor: ToolExecutor,
        toolCall: Transcript.ToolCall,
        didFail error: SendableError
    ) async {
        events.append(.failure(toolCall.id, error.localizedDescription))
    }
}

@Suite("ToolExecutionDelegate")
struct ToolExecutionDelegateTests {
    @Test("delegate execute path preserves default tool output")
    func defaultExecutePath() async throws {
        let delegate = RecordingToolDelegate()
        let executor = ToolExecutor(tools: [MockTool()])
        let call = try Transcript.ToolCall(
            id: "call_1",
            toolName: "mock_tool",
            argumentsJSON: #"{"input":"default"}"#
        )

        let result = try await executor.execute(
            toolCalls: [call],
            retryPolicy: .none,
            delegate: delegate
        )

        #expect(result.shouldContinue == true)
        #expect(result.outputs.map(\.text) == ["Result: default"])
        #expect(await delegate.recordedEvents == [
            .generated(["call_1"]),
            .decision("call_1"),
            .output("call_1", "Result: default")
        ])
    }

    @Test("delegate stop path prevents tool execution and continuation")
    func stopPath() async throws {
        let delegate = RecordingToolDelegate(decisions: ["call_1": .stop])
        let executor = ToolExecutor(tools: [MockTool()])
        let call = try Transcript.ToolCall(
            id: "call_1",
            toolName: "mock_tool",
            argumentsJSON: #"{"input":"ignored"}"#
        )

        let result = try await executor.execute(
            toolCalls: [call],
            retryPolicy: .none,
            delegate: delegate
        )

        #expect(result.shouldContinue == false)
        #expect(result.outputs.isEmpty)
        #expect(await delegate.recordedEvents == [
            .generated(["call_1"]),
            .decision("call_1")
        ])
    }

    @Test("delegate provided output path bypasses tool call")
    func providedOutputPath() async throws {
        let delegate = RecordingToolDelegate(decisions: [
            "call_1": .provideOutput([.text(.init(content: "Cached output"))])
        ])
        let executor = ToolExecutor(tools: [ThrowingMockTool()])
        let call = try Transcript.ToolCall(
            id: "call_1",
            toolName: "throwing_mock_tool",
            argumentsJSON: #"{"message":"do not execute"}"#
        )

        let result = try await executor.execute(
            toolCalls: [call],
            retryPolicy: .none,
            delegate: delegate
        )

        #expect(result.outputs.map(\.text) == ["Cached output"])
        #expect(await delegate.recordedEvents == [
            .generated(["call_1"]),
            .decision("call_1"),
            .output("call_1", "Cached output")
        ])
    }

    @Test("delegate observes thrown tool errors")
    func thrownToolErrors() async throws {
        let delegate = RecordingToolDelegate()
        let executor = ToolExecutor(tools: [ThrowingMockTool()])
        let call = try Transcript.ToolCall(
            id: "call_1",
            toolName: "throwing_mock_tool",
            argumentsJSON: #"{"message":"fail"}"#
        )

        await #expect(throws: ThrowingMockTool.AlwaysFailsError.self) {
            _ = try await executor.execute(toolCalls: [call], retryPolicy: .none, delegate: delegate)
        }

        let events = await delegate.recordedEvents
        #expect(events.count == 3)
        #expect(events[0] == .generated(["call_1"]))
        #expect(events[1] == .decision("call_1"))
        if case .failure("call_1", let message) = events[2] {
            #expect(message.contains("Always fails"))
        } else {
            Issue.record("Expected failure callback")
        }
    }

    @Test("delegate callback ordering is deterministic for multiple calls")
    func multipleCallOrdering() async throws {
        let delegate = RecordingToolDelegate()
        let executor = ToolExecutor(tools: [MockTool(), AnotherMockTool()])
        let first = try Transcript.ToolCall(
            id: "call_1",
            toolName: "mock_tool",
            argumentsJSON: #"{"input":"first"}"#
        )
        let second = try Transcript.ToolCall(
            id: "call_2",
            toolName: "another_tool",
            argumentsJSON: #"{"value":7}"#
        )

        let result = try await executor.execute(
            toolCalls: [first, second],
            retryPolicy: .none,
            delegate: delegate
        )

        #expect(result.outputs.map(\.id) == ["call_1", "call_2"])
        #expect(await delegate.recordedEvents == [
            .generated(["call_1", "call_2"]),
            .decision("call_1"),
            .output("call_1", "Result: first"),
            .decision("call_2"),
            .output("call_2", "Value doubled: 14")
        ])
    }

    @Test("ChatSession honors delegate stop without continuing generation")
    func chatSessionStopPath() async throws {
        let provider = MockTextProvider()
        let session = try await ChatSession(provider: provider, model: .llama3_2_1b)
        let call = try Transcript.ToolCall(
            id: "call_1",
            toolName: "mock_tool",
            argumentsJSON: #"{"input":"ignored"}"#
        )

        await provider.setQueuedGenerationResults([
            GenerationResult(
                text: "Need approval",
                tokenCount: 2,
                generationTime: 0,
                tokensPerSecond: 0,
                finishReason: .toolCalls,
                toolCalls: [call]
            ),
            .text("Should not be used")
        ])

        session.toolExecutor = ToolExecutor(tools: [MockTool()])
        session.toolExecutionDelegate = RecordingToolDelegate(decisions: ["call_1": .stop])

        let response = try await session.send("Try tool")

        #expect(response == "Need approval")
        #expect(session.messages.count == 2)
        #expect(session.messages.contains { $0.role == .tool } == false)
        #expect(await provider.generateCallCount == 1)
    }
}
