import Foundation
import XCTest
@testable import Liter8Core

/// AMFI's boot-time Developer Mode decision on the real T8020 kernels
/// (LITER8_FIXTURE_ROOT/offsets/<build>/kernelcache). The exact records are
/// pinned by the kernel-amfi-developer-mode fixtures.
final class KernelDeveloperModeResolverTests: XCTestCase {
    private func builds() throws -> [String] {
        let present = ["23H30", "23H128"].filter {
            FileManager.default.fileExists(atPath: liter8PrivateFixtureRoot(from: #filePath)
                .appendingPathComponent("offsets/\($0)/kernelcache").path)
        }
        if present.isEmpty { throw XCTSkip("no local iPad 8 kernel") }
        return present
    }

    private func kernel(_ build: String) throws -> Data {
        try Data(contentsOf: liter8PrivateFixtureRoot(from: #filePath)
            .appendingPathComponent("offsets/\(build)/kernelcache"))
    }

    private func word(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    func testRedirectsBothDisablesToTheMatchingEnable() throws {
        for build in try builds() {
            let image = BinaryImage(data: try kernel(build))
            let records = try KernelDeveloperModeResolver().resolve(in: image)
            XCTAssertEqual(records.map(\.id), ["kernel.amfi.developer-mode.decision.direct",
                                               "kernel.amfi.developer-mode.decision.acm"], build)
            let direct = records[0], acm = records[1]
            let disableLeaf = try XCTUnwrap(ARM64.branchLinkTarget(instruction: direct.originalWord!, at: direct.offset))
            let enableLeaf = try XCTUnwrap(ARM64.branchLinkTarget(instruction: direct.replacementWord!, at: direct.offset))
            // The leaves are MOV W0,#1 / MOV W0,#0, eight bytes apart.
            XCTAssertEqual(enableLeaf + 8, disableLeaf, build)
            XCTAssertEqual(try image.readUInt32(at: enableLeaf), ARM64.movW0One, build)
            XCTAssertEqual(try image.readUInt32(at: disableLeaf), ARM64.movW0Zero, build)
            // The ACM site's new target is a wrapper whose first call enables.
            let enableWrapper = try XCTUnwrap(ARM64.branchLinkTarget(instruction: acm.replacementWord!, at: acm.offset))
            XCTAssertEqual(try image.readUInt32(at: enableWrapper), ARM64.pacibsp, build)
            var firstCall: UInt64?
            for index in 1..<8 where firstCall == nil {
                let at = enableWrapper + UInt64(index * 4)
                if try image.readUInt32(at: at) >> 26 == 0b100101 { firstCall = at }
            }
            let call = try XCTUnwrap(firstCall, build)
            XCTAssertEqual(ARM64.branchLinkTarget(instruction: try image.readUInt32(at: call), at: call), enableLeaf, build)
        }
    }

    func testRefusesWhenAnotherDisableCallerExists() throws {
        for build in try builds() {
            var data = try kernel(build)
            let image = BinaryImage(data: data)
            let direct = try XCTUnwrap(KernelDeveloperModeResolver().resolve(in: image).first)
            let disableLeaf = try XCTUnwrap(ARM64.branchLinkTarget(instruction: direct.originalWord!, at: direct.offset))
            // Plant a BL disable_developer_mode inside an unrelated function:
            // a disable left outside the decision could still lock the mode off.
            let unrelated = try XCTUnwrap(KernelPPLDebugEntitlementsResolver().resolve(in: image).first).offset + 4
            let planted = try XCTUnwrap(ARM64.encodeDirectBranch(link: true, instructionOffset: unrelated, target: disableLeaf))
            data.replaceSubrange(Int(unrelated)..<Int(unrelated) + 4, with: word(planted))
            XCTAssertThrowsError(try KernelDeveloperModeResolver().resolve(in: BinaryImage(data: data)), build)
        }
    }

    func testRequiresTheDecisionDiagnostic() throws {
        for build in try builds() {
            var data = try kernel(build)
            for string in BinaryImage(data: data).findAll(utf8: KernelDeveloperModeResolver.decisionDiagnostic,
                                                          nulTerminated: true) {
                data[Int(string)] = UInt8(ascii: "a")
            }
            XCTAssertThrowsError(try KernelDeveloperModeResolver().resolve(in: BinaryImage(data: data)), build) { error in
                guard case PatchfinderError.noCandidate = error else {
                    return XCTFail("expected noCandidate, got \(error)")
                }
            }
        }
    }

    func testAppliedKernelIsAcceptedAgainAndNotRediscovered() throws {
        for build in try builds() {
            let image = BinaryImage(data: try kernel(build))
            let records = try KernelDeveloperModeResolver().resolve(in: image)
            let patched = BinaryImage(data: try GuardedPatchApplier.apply(records, to: image).data)
            XCTAssertEqual(try GuardedPatchApplier.apply(records, to: patched).data, patched.data, build)
            XCTAssertThrowsError(try KernelDeveloperModeResolver().resolve(in: patched), build)
        }
    }

    func testIsOptInThroughTheCodeSigningVariant() {
        XCTAssertEqual(KernelOptInResolvers.optInKey(forResolver: KernelDeveloperModeResolver.name),
                       KernelCodeSigningResolver.variantKey)
    }
}
