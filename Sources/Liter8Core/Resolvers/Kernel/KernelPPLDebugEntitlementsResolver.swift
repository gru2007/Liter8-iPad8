import Foundation

/// PPL's debug-entitlement gate: let an ad-hoc binary that carries
/// `get-task-allow`, `task_for_pid-allow`, `com.apple.private.cs.debugger` or
/// `com.apple.system-task-ports.control` start.
///
/// On T8020 the code-signing monitor (PPL) validates each code directory in a
/// chain of checks; one of them, owned by the only function that references
/// `task_for_pid-allow`, rejects a signature at trust level above 7 (every
/// ad-hoc binary under the PPL trust-cache patch is level 9) when it holds any
/// of those four entitlements, unless PPL's own developer-mode byte is set.
/// That byte is PPL state, separate from AMFI's: the boot plans force AMFI's
/// developer-mode accessor, which `security.mac.amfi.developer_mode_status`
/// then reports as 1, but nothing sets the PPL byte. The result on 23H30 and
/// 23H128 alike is a silent SIGKILL at exec for exactly those binaries, which
/// is why Sileo and launchctl had to be re-signed without them.
///
/// The gate reads the byte with `LDAPRB Wn,[Xn]` and takes `TBNZ Wn,#0,<allow>`
/// to a block that returns 1. This resolver turns that TBNZ into `B <allow>`,
/// i.e. "PPL developer mode on" for this one decision. The trust-level ≤ 7
/// branch ahead of it and every other PPL check are left as they are.
///
/// Measured on iPad11,6 / 23H128 before the patch: ad-hoc `hello` runs; the
/// same binary with `get-task-allow` or `task_for_pid-allow` exits 137 with no
/// AMFI or kernel log line. The 23H30 function is shape-identical.
public struct KernelPPLDebugEntitlementsResolver: Sendable {
    public static let name = "kernel-ppl-debug-entitlements"
    public init() {}

    /// Every entitlement the gate tests. All four must be referenced by the
    /// same function, which is what identifies it.
    static let entitlements = [
        "get-task-allow",
        "com.apple.private.cs.debugger",
        "com.apple.system-task-ports.control",
        "task_for_pid-allow",
    ]

    /// The developer-mode test sits a few instructions into the function
    /// (after the trust-level check). Measured at word 16 on both builds.
    private static let window = 32

    public func resolve(in image: BinaryImage) throws -> [PatchRecord] {
        let layout = try MachOLayout(image: image)
        let inspector = try BinaryInspector(image: image)

        func owners(_ text: String) throws -> Set<UInt64> {
            var result: Set<UInt64> = []
            for string in image.findAll(utf8: text, nulTerminated: true) {
                for reference in try layout.adrpAddReferences(toFileOffset: string) {
                    if let start = inspector.functionStart(beforeOrAt: reference.adrpOffset) {
                        result.insert(start)
                    }
                }
            }
            return result
        }
        var functions = try owners(Self.entitlements[0])
        for entitlement in Self.entitlements.dropFirst() {
            functions.formIntersection(try owners(entitlement))
        }
        guard functions.count == 1, let function = functions.first,
              let code = layout.executableFileRanges.first(where: { $0.contains(function) })
        else {
            if functions.isEmpty { throw PatchfinderError.noCandidate("PPL debug-entitlement gate") }
            throw PatchfinderError.ambiguousCandidate("PPL debug-entitlement gate", offsets: Array(functions))
        }

        var sites: [(branch: UInt64, allow: UInt64)] = []
        var cursor = function
        let limit = min(code.upperBound, function + UInt64(Self.window * 4))
        while cursor + 8 <= limit {
            defer { cursor += 4 }
            // LDAPRB Wt,[Xn]: 0x38BF_C000 with Rn and Rt variable.
            let load = try image.readUInt32(at: cursor)
            guard load & 0xFFFF_FC00 == 0x38BF_C000 else { continue }
            let register = load & 31
            // TBNZ Wt,#0,<allow>: b5 = 0, b40 = 0, same Rt as the load.
            let branchOffset = cursor + 4
            let branch = try image.readUInt32(at: branchOffset)
            guard branch & 0xFFF8_001F == 0x3700_0000 | register,
                  let allow = ARM64.testBranchTarget(instruction: branch, at: branchOffset),
                  code.contains(allow), allow > branchOffset,
                  try image.readUInt32(at: allow) == ARM64.movW0One,
                  try Self.returnsSoon(after: allow, in: image, within: code)
            else { continue }
            sites.append((branchOffset, allow))
        }
        guard sites.count == 1, let site = sites.first else {
            if sites.isEmpty { throw PatchfinderError.noCandidate("PPL developer-mode test in debug-entitlement gate") }
            throw PatchfinderError.ambiguousCandidate(
                "PPL developer-mode test in debug-entitlement gate", offsets: sites.map(\.branch))
        }
        guard let sourceVA = layout.virtualAddress(forFileOffset: site.branch),
              let targetVA = layout.virtualAddress(forFileOffset: site.allow),
              let always = ARM64.encodeDirectBranch(link: false, instructionOffset: sourceVA, target: targetVA)
        else {
            throw PatchfinderError.noCandidate("PPL debug-entitlement allow branch")
        }
        return [PatchRecord(
            id: "kernel.codesign.ppl-debug-entitlements",
            component: "kernelcache",
            offset: site.branch,
            original: try image.readUInt32(at: site.branch),
            replacement: always,
            summary: "Treat PPL developer mode as on for the debug-entitlement gate",
            evidence: [
                "only function referencing all of get-task-allow, cs.debugger, system-task-ports.control, task_for_pid-allow",
                "LDAPRB of the PPL developer-mode byte, TBNZ bit 0 to a MOV W0,#1 return",
                "branch forced to its existing target, not a fabricated one",
            ]
        )]
    }

    /// The allow block is `MOV W0,#1` then the epilogue: a RETAB/RET within a
    /// few words with no call in between.
    private static func returnsSoon(after allow: UInt64, in image: BinaryImage,
                                    within code: Range<UInt64>) throws -> Bool {
        var cursor = allow + 4
        while cursor + 4 <= code.upperBound, cursor < allow + 6 * 4 {
            let word = try image.readUInt32(at: cursor)
            if ARM64.isReturn(word) { return true }
            if word >> 26 == 0b100101 { return false } // BL
            cursor += 4
        }
        return false
    }
}
