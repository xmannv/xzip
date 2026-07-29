import XCTest
@testable import XZIPCore

/// Tests for FilterEngine, PasswordGenerator, PresetStore, InMemoryPasswordStore.
final class DomainServiceTests: XCTestCase {

    // MARK: - FilterEngine

    func testFilterExcludesMacNoise() {
        let filter = FilterEngine()
        XCTAssertTrue(filter.shouldExclude("/path/.DS_Store"))
        XCTAssertTrue(filter.shouldExclude("__MACOSX"))
        XCTAssertFalse(filter.shouldExclude("document.txt"))
    }

    func testFilterGlobMatching() {
        XCTAssertTrue(FilterEngine.matches(name: "backup.tmp", pattern: "*.tmp"))
        XCTAssertTrue(FilterEngine.matches(name: "a.log", pattern: "?.log"))
        XCTAssertFalse(FilterEngine.matches(name: "ab.log", pattern: "?.log"))
        XCTAssertTrue(FilterEngine.matches(name: "exact", pattern: "exact"))
    }

    // MARK: - PasswordGenerator

    func testPasswordGeneratorLengthAndCharset() {
        let pwd = PasswordGenerator.generate(options: .init(length: 32, includeSymbols: false))
        XCTAssertEqual(pwd.count, 32)
        // No symbols requested -> all alphanumeric.
        XCTAssertTrue(pwd.allSatisfy { $0.isLetter || $0.isNumber })
    }

    func testPasswordGeneratorUniqueness() {
        let a = PasswordGenerator.generate()
        let b = PasswordGenerator.generate()
        XCTAssertNotEqual(a, b, "Two generated passwords should almost never match")
    }

    // MARK: - PresetStore

    func testPresetStoreRoundtrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PresetStore(fileURL: tmp)
        // No file yet -> defaults.
        XCTAssertEqual(store.load().count, PresetStore.defaultPresets.count)

        let custom = [Preset(name: "My XZ", options: CompressionOptions(format: .xz, level: .ultra))]
        try store.save(custom)
        let reloaded = store.load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.name, "My XZ")
        XCTAssertEqual(reloaded.first?.options.format, .xz)
        XCTAssertEqual(reloaded.first?.options.level, .ultra)
    }

    func testPresetStorePreservesEncryptionMarkerButStripsRealPassword() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = PresetStore(fileURL: tmp)

        // The bundled "7z Encrypted" default carries the "" encryption marker so
        // the UI shows encryption ON (otherwise it silently produces plaintext).
        let encrypted = PresetStore.defaultPresets.first { $0.name == "7z Encrypted" }
        XCTAssertEqual(encrypted?.options.password, "",
                       "default encrypted preset must keep the '' marker")

        // Persisting: a real password is never written to disk, but the encrypt
        // intent (non-nil password) survives as the "" marker; nil stays nil.
        try store.save([
            Preset(name: "Secret", options: CompressionOptions(
                format: .sevenZip, level: .normal, password: "hunter2")),
            Preset(name: "Plain", options: CompressionOptions(format: .zip, level: .normal)),
        ])
        let reloaded = store.load()
        XCTAssertEqual(reloaded.first { $0.name == "Secret" }?.options.password, "")
        XCTAssertNil(reloaded.first { $0.name == "Plain" }?.options.password)
    }

    // MARK: - InMemoryPasswordStore

    func testInMemoryPasswordStore() throws {
        let store = InMemoryPasswordStore()
        try store.save(password: "hunter2", for: "archive.7z")
        XCTAssertEqual(try store.password(for: "archive.7z"), "hunter2")
        try store.delete(for: "archive.7z")
        XCTAssertNil(try store.password(for: "archive.7z"))
    }
}
