import Foundation
import XCTest
@testable import Liter8Core

/// Exact-build oracles for the clean 23H30 and 23H128 iPad 8 Wi-Fi artifacts.
/// Firmware binaries remain private; set LITER8_FIXTURE_ROOT to a directory
/// containing offsets/<build>/{kernelcache,kernelcache.im4p,iBEC.raw,mobileactivationd,asr}.
/// `kernelcache.im4p` is the IPSW's kernelcache.release.ipad11b, unmodified.
final class IPad8FixtureTests: XCTestCase {
    private var packageRoot: URL { liter8PackageRoot(from: #filePath) }

    /// Builds whose private binary is present; skip only when none is.
    private func availableBuilds(_ name: String) throws -> [String] {
        let builds = ["23H30", "23H128"].filter {
            FileManager.default.fileExists(atPath: liter8PrivateFixtureRoot(from: #filePath)
                .appendingPathComponent("offsets/\($0)/\(name)").path)
        }
        if builds.isEmpty { throw XCTSkip("no local iPad 8 \(name)") }
        return builds
    }

    func testT8020KernelRepackKeepsCompressionAndExactPAYPChild() throws {
        for build in try availableBuilds("kernelcache.im4p") {
            try checkKernelRepack(build: build)
        }
    }

    private func checkKernelRepack(build: String) throws {
        let source = liter8PrivateFixtureRoot(from: #filePath)
            .appendingPathComponent("offsets/\(build)/kernelcache.im4p")
        let original = try Data(contentsOf: source)
        let artifact = try FirmwareArtifact(data: original)
        XCTAssertEqual(artifact.fourcc, "krnl")

        let marker = Data("PAYP".utf8)
        guard let markerRange = original.range(of: marker, options: .backwards) else {
            return XCTFail("\(build) kernel has no PAYP metadata")
        }
        // The T8020 PAYP starts with A0 81 B9 30 81 B6 16 04 PAYP.
        // Copying ten bytes before the text also copies two unrelated bytes
        // from the preceding compression descriptor and breaks DER parsing.
        let paypStart = markerRange.lowerBound - 8
        XCTAssertEqual(original[paypStart], 0xA0)
        XCTAssertEqual(Data(original[(markerRange.lowerBound - 2)..<markerRange.lowerBound]),
                       Data([0x16, 0x04]))

        let rebuilt = try artifact.encoded(
            replacingPayloadWith: artifact.payload,
            preservingCompression: true
        )
        XCTAssertNotNil(rebuilt.range(of: Data("bvx2".utf8)))
        XCTAssertTrue(rebuilt.suffix(original.count - paypStart)
            .elementsEqual(original[paypStart..<original.endIndex]))
        XCTAssertEqual(try FirmwareArtifact(data: rebuilt).payload, artifact.payload)
    }

    func testRecoveredBootAndUserlandPlans() throws {
        try verifyRecoveredPlans(build: "23H30")
    }

    /// 26.7.2. Same plans and record counts as 23H30; its manifests bind the
    /// 23H128 binaries under offsets/23H128/.
    func testRecoveredBootAndUserlandPlans23H128() throws {
        try verifyRecoveredPlans(build: "23H128")
    }

    private func verifyRecoveredPlans(build: String) throws {
        let cases: [(String, String, Int)] = [
            ("kernel-credential-manager", "kernelcache", 50),
            ("kernel-sandbox-public", "kernelcache", 11),
            ("kernel-boot-public", "kernelcache", 118),
            ("kernel-boot-jit", "kernelcache", 141),
            ("kernel-ppl-debug-entitlements", "kernelcache", 1),
            ("kernel-amfi-developer-mode", "kernelcache", 2),
            ("kernel-task-access", "kernelcache", 15),
            ("kernel-ppl-trust-cache", "kernelcache", 1),
            ("ibec-restore", "iBEC.raw", 6),
            ("mobileactivationd", "mobileactivationd", 5),
            ("asr", "asr", 1),
        ]
        for (plan, binaryName, count) in cases {
            let filename = "\(plan)-j171aap-\(build).json"
            let binary = liter8PrivateFixtureRoot(from: #filePath)
                .appendingPathComponent("offsets/\(build)/\(binaryName)")
            guard FileManager.default.fileExists(atPath: binary.path) else {
                throw XCTSkip("local \(build) fixture is absent: \(binaryName)")
            }
            let manifest = try FixtureManifest.load(
                from: packageRoot.appendingPathComponent(
                    "fixtures/\(build)/j171aap/\(filename)"
                )
            )
            XCTAssertEqual(try manifest.verify(binaryAt: binary).count, count, filename)
        }
    }

    /// The 23H128 kernel selects its own profile, never 23H30's, and the
    /// task-access policy is reviewed for it.
    func test23H128KernelSelectsItsOwnProfile() throws {
        let binary = liter8PrivateFixtureRoot(from: #filePath).appendingPathComponent("offsets/23H128/kernelcache")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw XCTSkip("local 23H128 kernel is absent")
        }
        let image = try BinaryImage(contentsOf: binary)
        XCTAssertEqual(KernelResolverProfileRegistry.detect(in: image)?.id, "ios26-23H128-j171aap")
        XCTAssertEqual(try KernelTaskAccessResolver.requiredRecords(in: image).count, 15)
    }

    func testTaskAccessRejectsDamagedCallbacksAndConversionPaths() throws {
        for build in try availableBuilds("kernelcache") {
            try checkTaskAccessRejectsDamage(build: build)
        }
    }

    private func checkTaskAccessRejectsDamage(build: String) throws {
        let binary = liter8PrivateFixtureRoot(from: #filePath).appendingPathComponent("offsets/\(build)/kernelcache")
        let data = try Data(contentsOf: binary)
        let records = try KernelTaskAccessResolver().resolve(in: BinaryImage(data: data))
        XCTAssertEqual(records.count, 15)
        for id in ["kernel.task-access.amfi-get-task.0", "kernel.task-access.sandbox-get-task.0", "kernel.task-access.conversion.1", "kernel.task-access.control-out-trans"] {
            let record = try XCTUnwrap(records.first { $0.id == id })
            var damaged = data
            let p = Int(record.offset)
            damaged.replaceSubrange(p..<(p + 4), with: [0x1f, 0x20, 0x03, 0xd5])
            XCTAssertThrowsError(try KernelTaskAccessResolver().resolve(in: BinaryImage(data: damaged)), "\(build) \(id)")
        }
    }

    func testTaskAccessNeverOptsAnUnknownKernelIn() throws {
        let image = BinaryImage(data: Data(repeating: 0, count: 128))
        XCTAssertTrue(try KernelTaskAccessResolver.requiredRecords(in: image).isEmpty)
        XCTAssertThrowsError(try KernelTaskAccessResolver().resolve(in: image))
    }
}
