import Foundation
import Testing
@testable import EVA

@Suite("Waveform appearance preferences")
struct WaveformAppearancePreferencesTests {
    @Test("Zero line color round-trips through the preferences payload")
    func zeroLineColorRoundTrip() throws {
        let original = WaveformZeroLineColor(red: 0.9, green: 0.35, blue: 0.1)
        let decoded = WaveformZeroLineColor.decoded(from: original.encodedData)

        #expect(decoded == original)
    }

    @Test("Zero line color clamps invalid stored components")
    func zeroLineColorClampsStoredComponents() throws {
        let stored = WaveformZeroLineColor(red: -1, green: 0.4, blue: 2)
        let decoded = WaveformZeroLineColor.decoded(from: stored.encodedData)
        let rgb = try #require(decoded.customRGB)

        #expect(rgb.red == 0)
        #expect(rgb.green == 0.4)
        #expect(rgb.blue == 1)
    }

    @Test("Missing or corrupt zero line color uses the adaptive default")
    func zeroLineColorFallback() {
        #expect(WaveformZeroLineColor.decoded(from: Data()).customRGB == nil)
        #expect(WaveformZeroLineColor.decoded(from: Data("not-json".utf8)).customRGB == nil)
    }
}
