// DynamicTool.swift
// Conduit

/// A runtime-defined tool backed by a dynamic argument schema.
///
/// Use `DynamicTool` for tools discovered at runtime, such as MCP server tools,
/// where arguments are represented as ``GeneratedContent`` instead of a generated
/// Swift `@Generable` type.
public struct DynamicTool: Tool {
    public typealias Arguments = GeneratedContent
    public typealias Output = GeneratedContent

    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    public let includesSchemaInInstructions: Bool

    private let handler: @Sendable (GeneratedContent) async throws -> GeneratedContent

    public init(
        name: String,
        description: String,
        parameters: GenerationSchema,
        includesSchemaInInstructions: Bool = true,
        handler: @escaping @Sendable (GeneratedContent) async throws -> GeneratedContent
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.includesSchemaInInstructions = includesSchemaInInstructions
        self.handler = handler
    }

    public func call(arguments: GeneratedContent) async throws -> GeneratedContent {
        try await handler(arguments)
    }
}
