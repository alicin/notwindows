import Foundation
import Testing
@testable import notwindows

/// Builds minimal 32-bit PE files for analysis tests.
enum TestPE {
    struct Section {
        var name: String
        var bytes: Data
        var executable = true
    }

    static func build(_ sections: [Section], linkerVersion: UInt8 = 9, machine: UInt16 = 0x014C) -> Data {
        var file = Data(count: 0x200)
        func put32(_ value: UInt32, _ offset: Int) { withUnsafeBytes(of: value.littleEndian) { file.replaceSubrange(offset..<offset + 4, with: $0) } }
        func put16(_ value: UInt16, _ offset: Int) { withUnsafeBytes(of: value.littleEndian) { file.replaceSubrange(offset..<offset + 2, with: $0) } }
        file[0] = 0x4D; file[1] = 0x5A
        put32(0x40, 0x3C)
        file.replaceSubrange(0x40..<0x44, with: Data("PE\0\0".utf8))
        put16(machine, 0x44)
        put16(UInt16(sections.count), 0x46)
        put16(0xE0, 0x54)
        let optional = 0x58
        put16(0x10B, optional)
        file[optional + 2] = linkerVersion
        put32(16, optional + 92)
        var table = optional + 0xE0
        var raw = 0x200
        var rva: UInt32 = 0x1000
        var bodies = Data()
        for section in sections {
            let size = (section.bytes.count + 0x1FF) & ~0x1FF
            var name = Data(section.name.utf8.prefix(8))
            name.append(Data(count: 8 - name.count))
            file.replaceSubrange(table..<table + 8, with: name)
            put32(UInt32(section.bytes.count), table + 8)
            put32(rva, table + 12)
            put32(UInt32(size), table + 16)
            put32(UInt32(raw), table + 20)
            put32(section.executable ? 0x6000_0020 : 0x4000_0040, table + 36)
            var body = section.bytes
            body.append(Data(count: size - body.count))
            bodies.append(body)
            table += 40
            raw += size
            rva += UInt32((size + 0xFFF) & ~0xFFF)
        }
        return file + bodies
    }

    static func repeated(_ bytes: [UInt8], toAtLeast count: Int) -> Data {
        var data = Data()
        while data.count < count { data.append(contentsOf: bytes) }
        return data
    }

    /// x87-heavy code as old Visual C++ emitted it: loads, multiplies and stores around a frame pointer.
    static let x87Code: [UInt8] = [0x55, 0x8B, 0xEC, 0xD9, 0x45, 0x08, 0xD8, 0x4D, 0x0C, 0xD9, 0x5D, 0xFC, 0xDE, 0xC9, 0x8B, 0xE5, 0x5D, 0xC3]
    /// The same in SSE, plus some integer work.
    static let sseCode: [UInt8] = [0x55, 0x8B, 0xEC, 0xF3, 0x0F, 0x10, 0x45, 0x08, 0xF3, 0x0F, 0x59, 0x45, 0x0C, 0xF3, 0x0F, 0x11, 0x45, 0xFC,
                                   0x8B, 0x45, 0x08, 0x03, 0x45, 0x0C, 0x89, 0x45, 0xF8, 0x8B, 0xE5, 0x5D, 0xC3]
}

func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("notwindows-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
func makeFile(_ path: String, in folder: URL, contents: Data = Data()) throws -> URL {
    let url = folder.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url)
    return url
}

struct X87ScannerTests {
    @Test func decodesInstructionLengths() {
        // Immediates and addressing modes must be skipped exactly, or the x87 instructions after them are missed.
        let code: [UInt8] = [
            0xB8, 0xD9, 0xD9, 0xD9, 0xD9,                   // mov eax, 0xD9D9D9D9
            0xD9, 0xE8,                                     // fld1
            0x66, 0xB8, 0xDE, 0xDE,                         // mov ax, 0xDEDE
            0xDE, 0xC1,                                     // faddp
            0xF7, 0x05, 0xD8, 0xD8, 0xD8, 0xD8, 0xD9, 0xD9, 0xD9, 0xD9, // test dword [0xD8D8D8D8], 0xD9D9D9D9
            0xD9, 0xEE,                                     // fldz
            0xD9, 0x44, 0x24, 0x10,                         // fld dword [esp+0x10]
            0xF2, 0x0F, 0x59, 0xC1,                         // mulsd xmm0, xmm1
            0x0F, 0x28, 0xC8,                               // movaps xmm1, xmm0
            0xD9, 0x4D, 0x00,                               // not an instruction: D9 /1 with a memory operand
            0xC3,
        ]
        let counts = X87Scanner.count(Data(code))
        #expect(counts.x87 == 4)
        #expect(counts.sse == 2)
    }

    @Test func ratesHeavyLightAndEncryptedCode() throws {
        let heavy = try #require(PEFile(data: TestPE.build([.init(name: ".text", bytes: TestPE.repeated(TestPE.x87Code, toAtLeast: 64 * 1024))])))
        let usage = try #require(X87Scanner.measure(heavy))
        #expect(usage.level == .heavy)
        #expect(usage.share == 1)

        let modern = try #require(PEFile(data: TestPE.build([.init(name: ".text", bytes: TestPE.repeated(TestPE.sseCode, toAtLeast: 64 * 1024))], linkerVersion: 14)))
        #expect(X87Scanner.measure(modern)?.level == .light)

        var generator = SystemRandomNumberGenerator()
        let noise = Data((0..<(64 * 1024)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let encrypted = try #require(PEFile(data: TestPE.build([.init(name: ".text", bytes: noise), .init(name: ".bind", bytes: Data(TestPE.x87Code))])))
        let unknown = try #require(X87Scanner.measure(encrypted))
        #expect(unknown.isEncrypted)
        #expect(unknown.level == .unknown)
        #expect(unknown.isLegacyToolchain)

        let x64 = try #require(PEFile(data: TestPE.build([.init(name: ".text", bytes: TestPE.repeated(TestPE.x87Code, toAtLeast: 8192))], machine: 0x8664)))
        #expect(X87Scanner.measure(x64) == nil)
    }
}

struct EngineFingerprintTests {
    func analyze(_ path: String, in folder: URL, exe: Data = TestPE.build([.init(name: ".text", bytes: Data(TestPE.sseCode))])) throws -> ExecutableReport {
        ExecutableAnalyzer.analyze(try makeFile(path, in: folder, contents: exe))
    }

    @Test func recognisesBethesdaEngines() throws {
        let gamebryo = try temporaryFolder()
        try makeFile("Data/Fallout - Meshes.bsa", in: gamebryo)
        try makeFile("Data/FalloutNV.esm", in: gamebryo)
        #expect(try analyze("FalloutNV.exe", in: gamebryo).engine == .gamebryo)

        let morrowind = try temporaryFolder()
        try makeFile("Data Files/Morrowind.bsa", in: morrowind)
        #expect(try analyze("Morrowind.exe", in: morrowind).engine == .gamebryo)

        let creation = try temporaryFolder()
        try makeFile("Data/Fallout4 - Meshes.ba2", in: creation)
        try makeFile("Data/Fallout4.esm", in: creation)
        #expect(try analyze("Fallout4.exe", in: creation).engine == .creation)
    }

    @Test func tellsUnityRuntimesAndVersionsApart() throws {
        let il2cpp = try temporaryFolder()
        try makeFile("UnityPlayer.dll", in: il2cpp)
        try makeFile("GameAssembly.dll", in: il2cpp)
        try makeFile("Game_Data/globalgamemanagers", in: il2cpp, contents: Data(count: 20) + Data("2021.3.16f1".utf8) + Data(count: 40))
        let report = try analyze("Game.exe", in: il2cpp)
        #expect(report.engine == .unity)
        #expect(report.engineLabel == "Unity 2021.3 · IL2CPP")

        let mono = try temporaryFolder()
        try makeFile("UnityPlayer.dll", in: mono)
        try makeFile("Game_Data/Managed/Assembly-CSharp.dll", in: mono)
        #expect(try analyze("Game.exe", in: mono).engineLabel == "Unity Mono")
    }

    @Test func readsUnrealVersions() throws {
        let ue5 = try temporaryFolder()
        try FileManager.default.createDirectory(at: ue5.appendingPathComponent("Engine"), withIntermediateDirectories: true)
        let branch = Data("++UE5+Release-5.1".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let exe = TestPE.build([.init(name: ".text", bytes: Data(TestPE.sseCode)), .init(name: ".rdata", bytes: branch, executable: false)])
        let report = try analyze("Proj/Binaries/Win64/Proj-Win64-Shipping.exe", in: ue5, exe: exe)
        #expect(report.engineLabel == "Unreal Engine 5")

        let ue3 = try temporaryFolder()
        try FileManager.default.createDirectory(at: ue3.appendingPathComponent("ExampleGame/CookedPC"), withIntermediateDirectories: true)
        #expect(try analyze("Binaries/Win32/Example.exe", in: ue3).engineLabel == "Unreal Engine 3")
    }

    @Test func recognisesOtherEngines() throws {
        let doom3 = try temporaryFolder()
        try makeFile("base/pak000.pk4", in: doom3)
        #expect(try analyze("Doom3.exe", in: doom3).engineLabel == "id Tech 4")

        let eternal = try temporaryFolder()
        try makeFile("base/gameresources.resources", in: eternal)
        try makeFile("base/packagemapspec.json", in: eternal)
        #expect(try analyze("DOOMEternalx64vk.exe", in: eternal).engineLabel == "id Tech 7")

        let crysis = try temporaryFolder()
        try makeFile("Bin32/CrySystem.dll", in: crysis)
        #expect(try analyze("Bin32/Crysis.exe", in: crysis).engine == .cryEngine)

        let gta = try temporaryFolder()
        let exe = TestPE.build([.init(name: ".text", bytes: Data(TestPE.sseCode)), .init(name: ".rdata", bytes: Data("RenderWare Graphics 3.6".utf8), executable: false)])
        #expect(try analyze("gta_sa.exe", in: gta, exe: exe).engine == .renderWare)
    }
}

struct LauncherAndDRMTests {
    @Test func pointsLaunchersAtTheirGame() throws {
        let folder = try temporaryFolder()
        let launcher = try makeFile("FalloutNVLauncher.exe", in: folder, contents: Data(count: 300_000))
        try makeFile("FalloutNV.exe", in: folder, contents: Data(count: 3_000_000))
        try makeFile("CrashReporter.exe", in: folder, contents: Data(count: 9_000_000))
        try makeFile("BigTool.exe", in: folder, contents: Data(count: 5_000_000))
        #expect(ExecutableAnalyzer.launcherTarget(for: launcher) == "FalloutNV.exe")
        #expect(ExecutableAnalyzer.launcherTarget(for: folder.appendingPathComponent("FalloutNV.exe")) == nil)

        var game = Game(name: "New Vegas", executablePath: launcher.path)
        var report = ExecutableReport()
        report.launcherTarget = "FalloutNV.exe"
        let suggestions = MacRules.suggestions(for: report, executable: launcher, context: .init(installFolder: game.installFolder))
        let action = try #require(suggestions.first { if case .executable = $0.action { true } else { false } }?.action)
        #expect(action == .executable("FalloutNV.exe"))
        #expect(!action.isSatisfied(by: game, state: CompatState()))
        action.apply(to: &game)
        #expect(game.executableURL?.lastPathComponent == "FalloutNV.exe")
        #expect(action.isSatisfied(by: game, state: CompatState()))
        #expect(CompatAction.executable("falloutnv.EXE").isSatisfied(by: game, state: CompatState()))
    }

    @Test func notesSteamStub() throws {
        let folder = try temporaryFolder()
        let exe = try makeFile("Game.exe", in: folder, contents: TestPE.build([.init(name: ".text", bytes: Data(TestPE.sseCode)), .init(name: ".bind", bytes: Data(count: 64))]))
        let report = ExecutableAnalyzer.analyze(exe)
        #expect(report.hasSteamStub)
        #expect(MacRules.notes(for: report, context: .init(isSteamGame: true)).contains { $0.kind == .info && $0.text.contains("Steam is signed in") })
    }
}

struct X87RuleTests {
    func report(_ usage: X87Usage) -> ExecutableReport {
        var report = ExecutableReport()
        report.x87 = usage
        return report
    }

    @Test func suggestsRosettaX87OnlyWhereItHelpsAndWorks() {
        let exe = URL(fileURLWithPath: "/tmp/game.exe")
        let heavy = report(X87Usage(density: 20, share: 0.97, isEncrypted: false, linkerVersion: 7))
        let suggestion = MacRules.suggestions(for: heavy, executable: exe).first { $0.action == .rosettaX87(true) }
        #expect(suggestion?.recommended == true)

        #expect(!MacRules.suggestions(for: heavy, executable: exe, context: .init(supportsRosettaX87: false)).contains { $0.action == .rosettaX87(true) })
        #expect(MacRules.notes(for: heavy, context: .init(supportsRosettaX87: false)).contains { $0.text.contains("rosettax87") })

        let encrypted = report(X87Usage(density: 0, share: 0, isEncrypted: true, linkerVersion: 9))
        #expect(MacRules.suggestions(for: encrypted, executable: exe).first { $0.action == .rosettaX87(true) }?.recommended == false)

        let modern = report(X87Usage(density: 0, share: 0, isEncrypted: true, linkerVersion: 14))
        #expect(!MacRules.suggestions(for: modern, executable: exe).contains { $0.action == .rosettaX87(true) })
        #expect(!MacRules.suggestions(for: report(X87Usage(density: 2, share: 0.5, isEncrypted: false, linkerVersion: 14)), executable: exe)
            .contains { $0.action == .rosettaX87(true) })
    }

    @Test func skipsRedistributablesAlreadyInThePrefix() throws {
        let prefix = try temporaryFolder()
        var dosHeader = Data(count: 0x80)
        dosHeader[0] = 0x4D; dosHeader[1] = 0x5A
        dosHeader.replaceSubrange(0x4E..<0x6E, with: Data("This program cannot be run in DO".utf8))
        try makeFile("drive_c/windows/syswow64/d3dx9_38.dll", in: prefix, contents: dosHeader)
        var placeholder = Data(count: 0x80)
        placeholder.replaceSubrange(0x40..<0x50, with: Data("Wine builtin DLL".utf8))
        try makeFile("drive_c/windows/syswow64/x3daudio1_7.dll", in: prefix, contents: placeholder)

        var report = ExecutableReport()
        report.imports = ["d3dx9_38.dll", "x3daudio1_7.dll"]
        let verbs = MacRules.suggestions(for: report, executable: URL(fileURLWithPath: "/tmp/game.exe"), context: .init(prefix: prefix)).compactMap { suggestion -> String? in
            if case .winetricks(let verb) = suggestion.action { verb } else { nil }
        }
        #expect(verbs == ["xact"])
        #expect(MacRules.verb(forDLL: "MSVCP140.dll")?.verb == "vcrun2022")
    }
}
