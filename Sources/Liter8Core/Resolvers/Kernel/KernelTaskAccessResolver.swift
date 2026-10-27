import Foundation

/// Task-port policy for the opt-in T8020 research boot. This is separate from
/// executable-page policy: permitting a debugger does not grant a task port.
/// MACF callbacks return errno (zero grants access); conversion checks return
/// a Mach error. Retain the latter's object validation and take its self path.
public struct KernelTaskAccessResolver: Sendable {
    public static let name = "kernel-task-access"
    static let variantKey = "kernel-task-access"
    public init() {}

    static func requiredRecords(in image: BinaryImage) throws -> [PatchRecord] {
        guard KernelResolverProfileRegistry.detect(in: image)?.variants(for: variantKey) != nil else {
            return []
        }
        return try Self().resolve(in: image)
    }

    public func resolve(in image: BinaryImage) throws -> [PatchRecord] {
        guard KernelResolverProfileRegistry.detect(in: image)?.id == "ios26-23H30-j171aap" else {
            throw PatchfinderError.noCandidate("task-access policy is not reviewed for this kernel")
        }
        let layout = try MachOLayout(image: image)
        let inspector = try BinaryInspector(image: image)
        var records: [PatchRecord] = []

        // Both entitlement references must belong to the same flavor-aware
        // AMFI callback. Other functions use the same strings for exec policy.
        func owners(_ text: String) throws -> Set<UInt64> {
            var result: Set<UInt64> = []
            for string in image.findAll(utf8: text, nulTerminated: true) {
                for ref in try layout.adrpAddReferences(toFileOffset: string) {
                    if let start = inspector.functionStart(beforeOrAt: ref.adrpOffset) {
                        result.insert(start)
                    }
                }
            }
            return result
        }
        let amfi = try owners("task_for_pid-allow").intersection(owners("com.apple.system-task-ports.read"))
        let candidates = try amfi.filter { start in
            guard try image.readUInt32(at: start) == 0xd503237f,
                  try image.readUInt32(at: start + 4) == 0xd10143ff else { return false }
            return try (0..<32).contains { try image.readUInt32(at: start + UInt64($0 * 4)) == 0x71000edf }
        }
        guard candidates.count == 1, let callback = candidates.first else {
            throw PatchfinderError.ambiguousCandidate("AMFI task flavor callback", offsets: Array(candidates))
        }
        records += try stub(at: callback, id: "amfi-get-task", in: image, layout: layout)

        // XNU mac_policy_ops ABI: slots 97/98 are expose/get with flavor;
        // 157 is proc_check_debug. Null callbacks require no patch.
        let table = try sandboxTable(in: image)
        for (slot, name) in [(97, "sandbox-expose-task"), (98, "sandbox-get-task"), (157, "sandbox-debug")] {
            let target = UInt64(try image.readUInt32(at: table + UInt64(slot * 8)))
            guard target != 0 else { throw PatchfinderError.noCandidate("Sandbox \(name) callback") }
            records += try stub(at: target, id: name, in: image, layout: layout)
        }

        // PongoOS's task_conversion_eval strategy: preserve task_require and
        // Developer Mode/object checks, then force caller == victim. Match
        // the complete kernel_task comparison + paired platform-query block.
        let shape: [(UInt32, UInt32)] = [
            (0x90000000, 0x9f000000), (0xf9400000, 0xffc00000),
            (0xeb00001f, 0xffe0fc1f), (0x54000000, 0xff00001f),
            (0xeb00001f, 0xffe0fc1f), (0x54000000, 0xff00001f),
            (0xaa0003f0, 0xfffffff0), (0xaa0003e0, 0xffe0ffff),
            (0x94000000, 0xfc000000), (0x34000000, 0xff00001f),
            (0xaa1003e0, 0xfff0ffff), (0x94000000, 0xfc000000),
            (0x34000000, 0xff00001f),
        ]
        var conversionSites: [UInt64] = []
        for range in layout.executableFileRanges {
            var p = (range.lowerBound + 3) & ~UInt64(3)
            while p + UInt64(shape.count * 4) <= range.upperBound {
                if try shape.enumerated().allSatisfy({ i, pair in
                    try image.readUInt32(at: p + UInt64(i * 4)) & pair.1 == pair.0
                }) {
                    let load = try image.readUInt32(at: p + 4)
                    let cmp = try image.readUInt32(at: p + 8)
                    let query1 = ARM64.branchLinkTarget(instruction: try image.readUInt32(at: p + 32), at: p + 32)
                    let query2 = ARM64.branchLinkTarget(instruction: try image.readUInt32(at: p + 44), at: p + 44)
                    let before = p - 8
                    let selfCmp = try image.readUInt32(at: before)
                    if load & 31 == (cmp >> 16) & 31,
                       selfCmp & 0xffe0fc1f == 0xeb00001f,
                       try image.readUInt32(at: p - 4) & 0xff00001f == 0x54000000,
                       query1 != nil, query1 == query2 {
                        conversionSites.append(before)
                    }
                }
                p += 4
            }
        }
        guard conversionSites.count == 2 else {
            throw PatchfinderError.ambiguousCandidate("two T8020 task conversion paths", offsets: conversionSites)
        }
        for (index, site) in conversionSites.sorted().enumerated() {
            records.append(PatchRecord(id: "kernel.task-access.conversion.\(index)", component: "kernelcache",
                offset: site, original: try image.readUInt32(at: site), replacement: 0xeb1f03ff,
                summary: "Take the caller-equals-victim task conversion path",
                evidence: ["paired same-target platform queries", "kernel_task load and two comparisons", "exactly two conversion paths in reviewed T8020 kernel"]))
        }
        // Developer Mode is inlined here: patching developer_mode_state's
        // exported body does not affect this earlier foreign-control gate.
        // Out-trans returns IP_DEAD before reaching the platform comparison.
        // Force only its caller==victim branch, after task_require validation.
        let earlyShape: [(UInt32, UInt32)] = [
            (0x90000008, 0x9f00001f), (0xf9400108, 0xffc003ff),
            (0xb4000008, 0xff00001f), (0x39400108, 0xffffffff),
            (0x37000008, 0xfff8001f), (0xeb01001f, 0xffffffff),
            (0x54000000, 0xff00001f), (0x35000003, 0xff00001f),
            (0xaa0003f3, 0xffffffff), (0xaa0103e0, 0xffffffff),
            (0xaa0103f4, 0xffffffff), (0xaa0203f5, 0xffffffff),
            (0x94000000, 0xfc000000), (0xaa1403e1, 0xffffffff),
            (0xaa0003e8, 0xffffffff), (0xaa1303e0, 0xffffffff),
            (0x34000008, 0xff00001f), (0x52800008, 0xffffffff),
        ]
        var earlySites: [UInt64] = []
        for site in conversionSites where site >= 72 {
            let start = site - 72
            guard try earlyShape.enumerated().allSatisfy({ i, pair in
                try image.readUInt32(at: start + UInt64(i * 4)) & pair.1 == pair.0
            }) else { continue }
            let compare = site - 52
            guard ARM64.conditionalTarget(instruction: try image.readUInt32(at: start + 8), at: start + 8) == compare,
                  ARM64.testBranchTarget(instruction: try image.readUInt32(at: start + 16), at: start + 16) == site - 4,
                  ARM64.conditionalTarget(instruction: try image.readUInt32(at: compare + 4), at: compare + 4) == site - 4,
                  ARM64.conditionalTarget(instruction: try image.readUInt32(at: compare + 8), at: compare + 8) == site - 4 else { continue }
            earlySites.append(compare)
        }
        guard earlySites.count == 1, let early = earlySites.first else {
            throw PatchfinderError.ambiguousCandidate("inlined Developer Mode task out-trans gate", offsets: earlySites)
        }
        records.append(PatchRecord(id: "kernel.task-access.control-out-trans", component: "kernelcache",
            offset: early, original: try image.readUInt32(at: early), replacement: 0xeb1f03ff,
            summary: "Take the self path before the inlined foreign-control Developer Mode denial",
            evidence: ["Developer Mode byte load, caller comparison, flavor branch and corpse query",
                       "three branches converge on zero-result continuation", "task_require and null validation remain before this gate"]))
        return records
    }

    private func stub(at target: UInt64, id: String, in image: BinaryImage, layout: MachOLayout) throws -> [PatchRecord] {
        guard layout.executableFileRanges.contains(where: { target >= $0.lowerBound && target + 12 <= $0.upperBound }),
              try image.readUInt32(at: target) == 0xd503237f else {
            throw PatchfinderError.invalidFixture("\(id) is not an authenticated executable callback")
        }
        return try [ARM64.btiC, ARM64.movW0Zero, ARM64.ret].enumerated().map { index, word in
            let offset = target + UInt64(index * 4)
            return PatchRecord(id: "kernel.task-access.\(id).\(index)", component: "kernelcache",
                offset: offset, original: try image.readUInt32(at: offset), replacement: word,
                summary: "Grant \(id) with an errno-zero BTI-compatible callback",
                evidence: ["reviewed T8020 MACF callback", "BTI landing pad; no unbalanced PAC or stack frame"])
        }
    }

    private func sandboxTable(in image: BinaryImage) throws -> UInt64 {
        let names = Set(image.findAll(utf8: "Sandbox", nulTerminated: true).map { UInt32($0) })
        let descriptions = Set(image.findAll(utf8: "Seatbelt sandbox policy", nulTerminated: true).map { UInt32($0) })
        var tables: [UInt64] = []
        var p: UInt64 = 0
        while p + 40 <= UInt64(image.count) {
            if names.contains(try image.readUInt32(at: p)), descriptions.contains(try image.readUInt32(at: p + 8)) {
                let table = UInt64(try image.readUInt32(at: p + 32))
                guard table.isMultiple(of: 8), table + 268 * 8 <= UInt64(image.count) else {
                    throw PatchfinderError.invalidFixture("Sandbox task policy table out of range")
                }
                tables.append(table)
            }
            p += 8
        }
        guard tables.count == 1, let table = tables.first else {
            throw PatchfinderError.ambiguousCandidate("Sandbox task policy table", offsets: tables)
        }
        return table
    }
}
