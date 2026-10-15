import Foundation

/// How much of a 32-bit program's floating-point math runs on the x87 FPU, which Rosetta 2 emulates slowly and
/// rosettax87 speeds up. Visual C++ compiled 32-bit float math to x87 until 2012 made SSE2 the default.
struct X87Usage: Equatable {
    enum Level { case heavy, moderate, light, unknown }

    /// x87 instructions per KB of code.
    var density: Double
    /// x87's share of floating-point instructions, against SSE.
    var share: Double
    /// The code is encrypted (SteamStub, packers), so it couldn't be measured.
    var isEncrypted: Bool
    var linkerVersion: UInt8

    // Calibrated on old 32-bit games (13–29 per KB, ≥ 95% x87), modern Visual C++ builds (1–4 per KB, about half
    // SSE) and Wine's own 32-bit DLLs (none above 4).
    var level: Level {
        if isEncrypted { return .unknown }
        guard share >= 0.85 else { return .light }
        if density >= 8 { return .heavy }
        if density >= 4 { return .moderate }
        return .light
    }

    /// Built with Visual C++ 2010 or older, whose 32-bit float math is x87 unless told otherwise.
    var isLegacyToolchain: Bool { (1..<11).contains(linkerVersion) }
}

enum X87Scanner {
    static func measure(_ pe: PEFile) -> X87Usage? {
        guard case .i386 = pe.machine else { return nil }
        // SteamStub's own loader lives in .bind; the game's code is the rest.
        let code = pe.sections.filter { $0.isExecutable && $0.name != ".bind" }.map { pe.contents(of: $0) }
        let size = code.reduce(0) { $0 + $1.count }
        guard size >= 4096 else { return nil }
        if entropy(of: code.first { $0.count >= 4096 } ?? code[0]) >= 7.8 {
            return X87Usage(density: 0, share: 0, isEncrypted: true, linkerVersion: pe.linkerVersion)
        }
        var x87 = 0, sse = 0
        for section in code {
            let counts = count(section)
            x87 += counts.x87
            sse += counts.sse
        }
        return X87Usage(density: Double(x87) / (Double(size) / 1024), share: Double(x87) / Double(max(1, x87 + sse)),
                        isEncrypted: false, linkerVersion: pe.linkerVersion)
    }

    /// Shannon entropy in bits per byte over the first 256 KB. Compiled x86 code sits around 5–7; encrypted code at 8.
    static func entropy(of data: Data) -> Double {
        var histogram = [Int](repeating: 0, count: 256)
        let sample = data.prefix(256 * 1024)
        for byte in sample { histogram[Int(byte)] += 1 }
        let total = Double(sample.count)
        guard total > 0 else { return 0 }
        return histogram.reduce(0) { sum, n in
            guard n > 0 else { return sum }
            let p = Double(n) / total
            return sum - p * log2(p)
        }
    }

    /// Walks the code instruction by instruction, counting valid x87 instructions and SSE floating-point ones.
    /// Data mixed into the code throws the walk off briefly, but x86 resynchronises within a few instructions.
    static func count(_ code: Data) -> (x87: Int, sse: Int) {
        code.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> (Int, Int) in
            let n = bytes.count
            var i = 0, x87 = 0, sse = 0
            while i < n {
                var operandSize16 = false, address16 = false
                while i < n, isPrefix(bytes[i]) {
                    if bytes[i] == 0x66 { operandSize16 = true }
                    if bytes[i] == 0x67 { address16 = true }
                    i += 1
                }
                guard i < n else { break }
                let opcode = bytes[i]
                i += 1
                var hasModRM: Bool
                var immediate: Immediate
                var isSSE = false
                if opcode == 0x0F {
                    guard i < n else { break }
                    let second = bytes[i]
                    i += 1
                    switch second {
                    case 0x38: i += 1; hasModRM = true; immediate = .none
                    case 0x3A: i += 1; hasModRM = true; immediate = .byte
                    case 0x80...0x8F: hasModRM = false; immediate = .full
                    default:
                        hasModRM = !twoByteWithoutModRM.contains(second)
                        immediate = twoByteWithByteImmediate.contains(second) ? .byte : .none
                        isSSE = sseFloat.contains(second)
                    }
                } else {
                    let info = oneByte[Int(opcode)]
                    hasModRM = info.modRM
                    immediate = info.immediate
                }
                var modRM: UInt8 = 0
                if hasModRM {
                    guard i < n else { break }
                    modRM = bytes[i]
                    i += 1
                    let mod = modRM >> 6, reg = (modRM >> 3) & 7, rm = modRM & 7
                    if immediate == .group { immediate = reg < 2 ? (opcode == 0xF6 ? .byte : .full) : .none }
                    if mod != 3 {
                        if address16 {
                            if mod == 0 && rm == 6 { i += 2 } else if mod == 1 { i += 1 } else if mod == 2 { i += 2 }
                        } else {
                            if rm == 4 {
                                let sib = i < n ? bytes[i] : 0
                                i += 1
                                if mod == 0 && sib & 7 == 5 { i += 4 }
                            }
                            if mod == 0 && rm == 5 { i += 4 } else if mod == 1 { i += 1 } else if mod == 2 { i += 4 }
                        }
                    }
                }
                switch immediate {
                case .none, .group: break
                case .byte: i += 1
                case .word: i += 2
                case .full: i += operandSize16 ? 2 : 4
                case .address: i += address16 ? 2 : 4
                case .farPointer: i += 6
                case .enter: i += 3
                }
                if (0xD8...0xDF).contains(opcode) {
                    if isValidX87(opcode, modRM) { x87 += 1 }
                } else if isSSE {
                    sse += 1
                }
            }
            return (x87, sse)
        }
    }

    private enum Immediate { case none, byte, word, full, address, group, farPointer, enter }

    private static func isPrefix(_ byte: UInt8) -> Bool {
        switch byte {
        case 0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65, 0x66, 0x67: true
        default: false
        }
    }

    private static let oneByte: [(modRM: Bool, immediate: Immediate)] = {
        var table = [(modRM: Bool, immediate: Immediate)](repeating: (false, .none), count: 256)
        func set(_ opcodes: [Int], _ modRM: Bool, _ immediate: Immediate = .none) { for op in opcodes { table[op] = (modRM, immediate) } }
        for base in stride(from: 0x00, through: 0x38, by: 8) {
            set(Array(base...(base + 3)), true)
            set([base + 4], false, .byte)
            set([base + 5], false, .full)
        }
        set([0x62, 0x63], true)
        set([0x68], false, .full); set([0x69], true, .full); set([0x6A], false, .byte); set([0x6B], true, .byte)
        set(Array(0x70...0x7F), false, .byte)
        set([0x80, 0x82, 0x83], true, .byte); set([0x81], true, .full)
        set(Array(0x84...0x8F), true)
        set([0x9A], false, .farPointer)
        set(Array(0xA0...0xA3), false, .address)
        set([0xA8], false, .byte); set([0xA9], false, .full)
        set(Array(0xB0...0xB7), false, .byte); set(Array(0xB8...0xBF), false, .full)
        set([0xC0, 0xC1, 0xC6], true, .byte); set([0xC7], true, .full)
        set([0xC2, 0xCA], false, .word); set([0xC4, 0xC5], true)
        set([0xC8], false, .enter); set([0xCD, 0xD4, 0xD5], false, .byte)
        set(Array(0xD0...0xD3), true)
        set(Array(0xD8...0xDF), true)
        set(Array(0xE0...0xE7), false, .byte)
        set([0xE8, 0xE9], false, .full); set([0xEA], false, .farPointer); set([0xEB], false, .byte)
        set([0xF6, 0xF7], true, .group)
        set([0xFE, 0xFF], true)
        return table
    }()

    private static let twoByteWithoutModRM: Set<UInt8> = [0x05, 0x06, 0x07, 0x08, 0x09, 0x0B, 0x0E, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x37, 0x77,
                                                          0xA0, 0xA1, 0xA2, 0xA8, 0xA9, 0xAA, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF]
    private static let twoByteWithByteImmediate: Set<UInt8> = [0x70, 0x71, 0x72, 0x73, 0xA4, 0xAC, 0xBA, 0xC2, 0xC4, 0xC5, 0xC6]
    /// Scalar and packed SSE float moves, arithmetic, conversions and compares.
    private static let sseFloat: Set<UInt8> = Set([0x10, 0x11, 0x28, 0x29, 0x2A, 0x2C, 0x2D, 0x2E, 0x2F, 0xC2] + Array(0x51...0x5F))

    /// Whether an x87 opcode and ModRM byte form a real instruction. Random bytes fail this about one time in eight.
    static func isValidX87(_ opcode: UInt8, _ modRM: UInt8) -> Bool {
        let reg = (modRM >> 3) & 7
        guard modRM >> 6 == 3 else {
            switch opcode {
            case 0xD9: return reg != 1
            case 0xDB: return reg != 4 && reg != 6
            case 0xDD: return reg != 5
            default: return true
            }
        }
        switch opcode {
        case 0xD9: return modRM <= 0xD0 || [0xE0, 0xE1, 0xE4, 0xE5].contains(modRM) || (0xE8...0xEE).contains(modRM) || modRM >= 0xF0
        case 0xDA: return modRM < 0xE0 || modRM == 0xE9
        case 0xDB: return modRM < 0xE0 || modRM == 0xE2 || modRM == 0xE3 || (0xE8..<0xF8).contains(modRM)
        case 0xDD: return modRM < 0xC8 || (0xD0..<0xF0).contains(modRM)
        case 0xDE: return modRM < 0xD0 || modRM == 0xD9 || modRM >= 0xE0
        case 0xDF: return modRM < 0xC8 || modRM == 0xE0 || (0xE8..<0xF8).contains(modRM)
        default: return true
        }
    }
}
