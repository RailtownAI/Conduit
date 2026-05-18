import Foundation
import Testing
@testable import ConduitAdvanced

private enum CustomOptionsProviderA {}
private enum CustomOptionsProviderB {}

private struct ProviderCustomOptions: Codable, Sendable, Equatable {
    var mode: String
    var budget: Int
}

private struct ThrowingCustomOptions: Codable, Sendable {
    func encode(to encoder: Encoder) throws {
        throw EncodingError.invalidValue(
            "bad",
            EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Intentional test failure")
        )
    }
}

private func requireSendable<T: Sendable>(_ value: T) {}

@Suite("GenerateConfig Custom Options")
struct GenerateConfigCustomOptionsTests {
    @Test("custom options are typed, isolated, and removable")
    func typedIsolationAndRemoval() {
        var config = GenerateConfig.default
        let options = ProviderCustomOptions(mode: "thinking", budget: 256)

        config[custom: CustomOptionsProviderA.self] = options

        let a: ProviderCustomOptions? = config[custom: CustomOptionsProviderA.self]
        let b: ProviderCustomOptions? = config[custom: CustomOptionsProviderB.self]
        #expect(a == options)
        #expect(b == nil)

        config[custom: CustomOptionsProviderA.self] = Optional<ProviderCustomOptions>.none
        let removed: ProviderCustomOptions? = config[custom: CustomOptionsProviderA.self]
        #expect(removed == nil)
    }

    @Test("custom options round trip without changing normal config")
    func codableRoundTrip() throws {
        var config = GenerateConfig.default.maxTokens(512).temperature(0.2)
        config[custom: CustomOptionsProviderA.self] = ProviderCustomOptions(mode: "cache", budget: 32)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GenerateConfig.self, from: data)

        let options: ProviderCustomOptions? = decoded[custom: CustomOptionsProviderA.self]
        #expect(options == ProviderCustomOptions(mode: "cache", budget: 32))
        #expect(decoded.maxTokens == 512)
        #expect(decoded.temperature == 0.2)
    }

    @Test("old config JSON decodes with no custom options")
    func oldJSONDecode() throws {
        let json = """
        {
          "maxTokens": 123,
          "temperature": 0.7,
          "topP": 0.9,
          "repetitionPenalty": 1.0,
          "frequencyPenalty": 0.0,
          "presencePenalty": 0.0,
          "stopSequences": [],
          "returnLogprobs": false,
          "tools": [],
          "toolChoice": { "auto": {} }
        }
        """

        let decoded = try JSONDecoder().decode(GenerateConfig.self, from: Data(json.utf8))
        let options: ProviderCustomOptions? = decoded[custom: CustomOptionsProviderA.self]

        #expect(decoded.maxTokens == 123)
        #expect(options == nil)
    }

    @Test("config remains Sendable with custom options")
    func sendableCompilation() {
        var config = GenerateConfig.default
        config[custom: CustomOptionsProviderA.self] = ProviderCustomOptions(mode: "sendable", budget: 1)
        requireSendable(config)
    }

    @Test("throwing custom options API reports encoding failures without aborting")
    func throwingSetterReportsEncodingFailures() {
        var config = GenerateConfig.default
        config[custom: CustomOptionsProviderA.self] = ProviderCustomOptions(mode: "valid", budget: 1)

        #expect(throws: EncodingError.self) {
            try config.setCustomOptions(ThrowingCustomOptions(), for: CustomOptionsProviderA.self)
        }
        let preserved: ProviderCustomOptions? = config[custom: CustomOptionsProviderA.self]
        #expect(preserved == ProviderCustomOptions(mode: "valid", budget: 1))

        config[custom: CustomOptionsProviderA.self] = ThrowingCustomOptions()
        let removed: ProviderCustomOptions? = config[custom: CustomOptionsProviderA.self]
        #expect(removed == nil)
    }
}
