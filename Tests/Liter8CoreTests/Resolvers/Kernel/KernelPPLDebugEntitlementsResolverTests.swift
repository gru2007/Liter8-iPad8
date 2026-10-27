import Foundation
import XCTest
@testable import Liter8Core

/// PPL debug-entitlement gate on the real T8020 kernels. Needs the private
/// kernels under LITER8_FIXTURE_ROOT/offsets/<build>/kernelcache; the exact
/// records are pinned by the kernel-ppl-debug-entitlements fixtures.
final class KernelPPLDebugEntitlementsResolverTests: XCTestCase {
    private func kernel(_ build: String) throws -> Data {
        let url = liter8PrivateFixtureRoot(from: #filePath)
            .appendingPathComponent("offsets/\(build)/kernelcache")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("local \(build) kernel is absent")
        }
        return try Data(contentsOf: url)
    }

    private func builds() throws -> [String] {
        let present = ["23H30", "23H128"].filter {
            FileManager.default.fileExists(atPath: liter8PrivateFixtureRoot(from: #filePath)
                .appendingPathComponent("offsets/\($0)/kernelcache").path)
        }
        if present.isEmpty { throw XCTSkip("no local iPad 8 kernel") }
        return present
    }

    func testForcesTheDeveloperModeBranchToItsAllowBlock() throws {
        for build in try builds() {
            let data = try kernel(build)
            let records = try KernelPPLDebugEntitlementsResolver().resolve(in: BinaryImage(data: data))
            XCTAssertEqual(records.count, 1, build)
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(record.originalWord, 0x3700_0AE8, build)   // TBNZ W8,#0,+0x15c
            XCTAssertEqual(record.replacementWord, 0x1400_0057, build) // B +0x15c, same target
            // The target is the MOV W0,#1 allow block in both encodings.
            let target = record.offset + 0x15c
            XCTAssertEqual(try BinaryImage(data: data).readUInt32(at: target), 0x5280_0020, build)
        }
    }

    func testRejectsADamagedDeveloperModeTest() throws {
        for build in try builds() {
            var data = try kernel(build)
            let record = try XCTUnwrap(KernelPPLDebugEntitlementsResolver().resolve(in: BinaryImage(data: data)).first)
            let at = Int(record.offset)
            data.replaceSubrange(at..<(at + 4), with: [0x1f, 0x20, 0x03, 0xd5]) // NOP
            XCTAssertThrowsError(try KernelPPLDebugEntitlementsResolver().resolve(in: BinaryImage(data: data)), build)
        }
    }

    func testRequiresEveryDebugEntitlementInTheSameFunction() throws {
        for build in try builds() {
            var data = try kernel(build)
            let image = BinaryImage(data: data)
            // Rename task_for_pid-allow: no function references all four any more.
            for string in image.findAll(utf8: "task_for_pid-allow", nulTerminated: true) {
                data[Int(string)] = UInt8(ascii: "T")
            }
            XCTAssertThrowsError(try KernelPPLDebugEntitlementsResolver().resolve(in: BinaryImage(data: data)), build) { error in
                guard case PatchfinderError.noCandidate = error else {
                    return XCTFail("expected noCandidate, got \(error)")
                }
            }
        }
    }

    func testAppliedKernelIsAcceptedAgainAndNotRediscovered() throws {
        for build in try builds() {
            let image = BinaryImage(data: try kernel(build))
            let records = try KernelPPLDebugEntitlementsResolver().resolve(in: image)
            let patched = BinaryImage(data: try GuardedPatchApplier.apply(records, to: image).data)
            XCTAssertEqual(try GuardedPatchApplier.apply(records, to: patched).data, patched.data, build)
            XCTAssertThrowsError(try KernelPPLDebugEntitlementsResolver().resolve(in: patched), build)
        }
    }

    func testOnlyTheIPadProfilesComposeIt() {
        XCTAssertEqual(KernelOptInResolvers.optInKey(forResolver: KernelPPLDebugEntitlementsResolver.name),
                       KernelCodeSigningResolver.variantKey)
        let optedIn = KernelResolverProfileRegistry.profiles
            .filter { $0.variants(for: KernelCodeSigningResolver.variantKey) != nil }.map(\.id).sorted()
        XCTAssertEqual(optedIn, ["ios26-23H128-j171aap", "ios26-23H30-j171aap"])
    }
}
