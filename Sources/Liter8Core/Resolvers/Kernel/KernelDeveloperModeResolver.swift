import Foundation

/// Make AMFI's boot-time Developer Mode decision turn the mode on, for real.
///
/// The boot plans already force `developer_mode_state()` (the XNU accessor) to
/// return 1, so `security.mac.amfi.developer_mode_status` reads 1. The mode
/// itself is a PPL byte, written only by the PPL toggle (call 100) that
/// `enable_developer_mode()` / `disable_developer_mode()` reach. On the
/// SEP-less boot AMFI's decision reads ACM: the ACM patches return success
/// without writing the answer, so "ACM says dev mode is" 0 and AMFI calls
/// disable; a failed mobile-obliteration query disables too. The PPL byte stays
/// off, and everything that consults PPL rather than the accessor treats the
/// device as Developer Mode off (hardware breakpoints among them).
///
/// It cannot simply be enabled later: the PPL toggle counts every call and
/// panics ("enabling developer mode incorrectly") when asked to enable on any
/// call but the first. So the fix is at the decision itself. Both disable
/// sites in AMFI's decision function are redirected to the matching enable
/// call, which makes every toggle of the boot an enable: the first one sets
/// the byte, the rest change nothing.
///
/// Guards, all derived from the binary:
///   - one pair of XNU leaves `MOV W0,#1; B t` / `MOV W0,#0; B t` with the same
///     target, and that target is a PPL trampoline (`MOV X15,#imm; B`);
///   - AMFI's enable and disable wrappers are the functions whose first call
///     is that enable / disable leaf;
///   - the decision function is the one referencing the "couldn't get mobile
///     obliteration status" diagnostic, and it holds exactly one direct call to
///     the disable leaf and one to the disable wrapper;
///   - nothing else in the kernel calls the disable leaf or the disable
///     wrapper, so no disable is left that could follow and lock the mode.
public struct KernelDeveloperModeResolver: Sendable {
    public static let name = "kernel-amfi-developer-mode"
    public init() {}

    /// Exact literal, trailing newline included: AMFI's os_log format.
    static let decisionDiagnostic =
        "AMFI: Disable developer mode since we couldn't get mobile obliteration status\n"

    private struct Call { let site: UInt64; let target: UInt64 }

    public func resolve(in image: BinaryImage) throws -> [PatchRecord] {
        let layout = try MachOLayout(image: image)
        let inspector = try BinaryInspector(image: image)
        let code = layout.executableFileRanges

        // 1. The XNU enable/disable leaves and their shared PPL trampoline.
        var leaves: [(enable: UInt64, disable: UInt64)] = []
        var calls: [Call] = []
        var jumps: [Call] = []
        for range in code {
            var offset = (range.lowerBound + 3) & ~UInt64(3)
            while offset + 4 <= range.upperBound {
                let word = try image.readUInt32(at: offset)
                if word >> 26 == 0b100101,
                   let target = ARM64.branchLinkTarget(instruction: word, at: offset) {
                    calls.append(Call(site: offset, target: target))
                } else if word >> 26 == 0b000101,
                          let target = ARM64.directBranchTarget(instruction: word, at: offset) {
                    jumps.append(Call(site: offset, target: target))
                }
                if word == ARM64.movW0One, offset + 16 <= range.upperBound,
                   try image.readUInt32(at: offset + 8) == ARM64.movW0Zero {
                    let first = try image.readUInt32(at: offset + 4)
                    let second = try image.readUInt32(at: offset + 12)
                    if first >> 26 == 0b000101, second >> 26 == 0b000101,
                       let a = ARM64.directBranchTarget(instruction: first, at: offset + 4),
                       let b = ARM64.directBranchTarget(instruction: second, at: offset + 12),
                       a == b, range.contains(a), a + 8 <= range.upperBound,
                       try image.readUInt32(at: a) & 0xFFE0_001F == 0xD280_000F, // MOV X15,#imm
                       try image.readUInt32(at: a + 4) >> 26 == 0b000101 {         // B dispatcher
                        leaves.append((offset, offset + 8))
                    }
                }
                offset += 4
            }
        }
        guard leaves.count == 1, let leaf = leaves.first else {
            if leaves.isEmpty { throw PatchfinderError.noCandidate("developer-mode enable/disable leaves") }
            throw PatchfinderError.ambiguousCandidate("developer-mode enable/disable leaves",
                                                      offsets: leaves.map(\.enable))
        }

        // 2. AMFI wrappers: functions whose first call is the leaf.
        func wrapper(calling leafOffset: UInt64, _ what: String) throws -> UInt64 {
            var found: Set<UInt64> = []
            for call in calls where call.target == leafOffset {
                guard let start = inspector.functionStart(beforeOrAt: call.site),
                      start != leafOffset else { continue }
                let firstCall = calls.first { $0.site >= start && $0.site <= call.site }
                if firstCall?.site == call.site, call.site - start <= 0x20 { found.insert(start) }
            }
            guard found.count == 1, let start = found.first else {
                if found.isEmpty { throw PatchfinderError.noCandidate("AMFI developer-mode \(what) wrapper") }
                throw PatchfinderError.ambiguousCandidate("AMFI developer-mode \(what) wrapper", offsets: Array(found))
            }
            return start
        }
        let enableWrapper = try wrapper(calling: leaf.enable, "enable")
        let disableWrapper = try wrapper(calling: leaf.disable, "disable")

        // 3. The decision function, by its own diagnostic.
        var decisions: Set<UInt64> = []
        for string in image.findAll(utf8: Self.decisionDiagnostic, nulTerminated: true) {
            for reference in try layout.adrpAddReferences(toFileOffset: string) {
                if let start = inspector.functionStart(beforeOrAt: reference.adrpOffset) {
                    decisions.insert(start)
                }
            }
        }
        guard decisions.count == 1, let decision = decisions.first else {
            if decisions.isEmpty { throw PatchfinderError.noCandidate("AMFI developer-mode decision") }
            throw PatchfinderError.ambiguousCandidate("AMFI developer-mode decision", offsets: Array(decisions))
        }
        let inDecision = { (site: UInt64) in inspector.functionStart(beforeOrAt: site) == decision }

        // 4. Every disable must come from the decision function.
        let disableLeafCalls = calls.filter { $0.target == leaf.disable }
        let disableWrapperCalls = calls.filter { $0.target == disableWrapper }
        let directSites = disableLeafCalls.filter { inDecision($0.site) }
        let wrapperSites = disableWrapperCalls.filter { inDecision($0.site) }
        guard directSites.count == 1, wrapperSites.count == 1,
              disableLeafCalls.allSatisfy({ inDecision($0.site) || inspector.functionStart(beforeOrAt: $0.site) == disableWrapper }),
              disableWrapperCalls.allSatisfy({ inDecision($0.site) }),
              !jumps.contains(where: { $0.target == leaf.disable || $0.target == disableWrapper }),
              calls.contains(where: { $0.target == enableWrapper && inDecision($0.site) })
        else {
            throw PatchfinderError.noCandidate(
                "AMFI developer-mode decision owning every disable (direct \(directSites.count), wrapper \(wrapperSites.count))")
        }

        func redirect(_ site: UInt64, to target: UInt64, id: String, summary: String,
                      evidence: String) throws -> PatchRecord {
            guard let from = layout.virtualAddress(forFileOffset: site),
                  let to = layout.virtualAddress(forFileOffset: target),
                  let word = ARM64.encodeDirectBranch(link: true, instructionOffset: from, target: to)
            else { throw PatchfinderError.noCandidate("developer-mode redirect \(id)") }
            return PatchRecord(
                id: id, component: "kernelcache", offset: site,
                original: try image.readUInt32(at: site), replacement: word,
                summary: summary,
                evidence: [
                    "decision function owns the obliteration-status diagnostic",
                    "enable/disable leaves share one PPL toggle trampoline",
                    evidence,
                    "no disable caller outside the decision function remains",
                ]
            )
        }
        return [
            try redirect(directSites[0].site, to: leaf.enable,
                         id: "kernel.amfi.developer-mode.decision.direct",
                         summary: "Enable instead of disable when the obliteration status is unavailable",
                         evidence: "BL disable_developer_mode becomes BL enable_developer_mode"),
            try redirect(wrapperSites[0].site, to: enableWrapper,
                         id: "kernel.amfi.developer-mode.decision.acm",
                         summary: "Enable instead of disable when ACM does not report Developer Mode",
                         evidence: "BL to the disable wrapper becomes BL to the enable wrapper"),
        ].sorted { $0.offset < $1.offset }
    }
}
