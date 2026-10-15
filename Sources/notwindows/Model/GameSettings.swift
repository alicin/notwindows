import Foundation

enum Direct3DBackend: String, Codable, CaseIterable, Identifiable {
    case wined3d, dxmt, dxvk, d3dmetal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wined3d: "WineD3D (OpenGL)"
        case .dxmt: "DXMT (Metal)"
        case .dxvk: "DXVK (Vulkan)"
        case .d3dmetal: "D3DMetal (Apple GPTK)"
        }
    }

    var detail: String {
        switch self {
        case .wined3d: "Built-in translation. Most compatible, slowest."
        case .dxmt: "Direct3D 10/11 straight to Metal. Good default for DX11 games."
        case .dxvk: "Direct3D 10/11 through Vulkan on Metal."
        case .d3dmetal: "Apple's Direct3D 11/12 layer. Needed for DX12 games. Apple Silicon only."
        }
    }
}

enum Direct3D9Backend: String, Codable, CaseIterable, Identifiable {
    case wined3d, d9vk
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wined3d: "WineD3D (OpenGL)"
        case .d9vk: "D9VK (Vulkan)"
        }
    }
}

enum VulkanDriver: String, Codable, CaseIterable, Identifiable {
    case moltenVK, kosmicKrisp
    var id: String { rawValue }

    var title: String {
        switch self {
        case .moltenVK: "MoltenVK"
        case .kosmicKrisp: "KosmicKrisp (Mesa)"
        }
    }

    static var platformDefault: VulkanDriver {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 26, minorVersion: 0, patchVersion: 0))
            ? .kosmicKrisp : .moltenVK
    }
}

enum DXVKVersion: String, Codable, CaseIterable, Identifiable {
    case automatic, legacy, modern
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .legacy: "1.10 (MoltenVK-friendly)"
        case .modern: "3.x (needs Vulkan 1.3)"
        }
    }
}

enum DXVKHUD: String, Codable, CaseIterable, Identifiable {
    case off, fps, full
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .fps: "FPS"
        case .full: "Full"
        }
    }

    var envValue: String? {
        switch self {
        case .off: nil
        case .fps: "fps"
        case .full: "api,devinfo,fps,version"
        }
    }
}

enum WindowsVersion: String, Codable, CaseIterable, Identifiable {
    case win11, win10, win81, win8, win7, vista, winxp64, winxp
    var id: String { rawValue }

    var title: String {
        switch self {
        case .win11: "Windows 11"
        case .win10: "Windows 10"
        case .win81: "Windows 8.1"
        case .win8: "Windows 8"
        case .win7: "Windows 7"
        case .vista: "Windows Vista"
        case .winxp64: "Windows XP (64-bit)"
        case .winxp: "Windows XP"
        }
    }
}

enum WineLogLevel: String, Codable, CaseIterable, Identifiable {
    case off, errors, verbose
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Quiet"
        case .errors: "Errors"
        case .verbose: "Verbose"
        }
    }

    /// The quiet level keeps the few channels that explain why a game didn't start: Wine checks a channel's flags
    /// before formatting anything, and these print only when a DLL fails to load, a display mode is refused or a
    /// message box opens, so they cost nothing measurable while giving Smart Setup the lines it learns from.
    var winedebug: String {
        switch self {
        case .off: "-all," + LogDiagnostics.channels
        case .errors: "err+all,warn-all,fixme-all,trace-all,trace+msgbox,-plugplay"
        case .verbose: "err+all,warn+all,fixme+all,+loaddll,+seh,+msgbox"
        }
    }
}

enum DLLOverrideMode: String, Codable, CaseIterable, Identifiable {
    case nativeThenBuiltin = "n,b"
    case builtinThenNative = "b,n"
    case native = "n"
    case builtin = "b"
    case disabled = ""
    var id: String { rawValue }

    var title: String {
        switch self {
        case .nativeThenBuiltin: "Native, then Built-in"
        case .builtinThenNative: "Built-in, then Native"
        case .native: "Native"
        case .builtin: "Built-in"
        case .disabled: "Disabled"
        }
    }
}

struct DLLOverride: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var mode: DLLOverrideMode
}

struct EnvironmentVariable: Codable, Hashable, Identifiable {
    var id = UUID()
    var key: String
    var value: String
}

/// A value in one of the game's .ini files. `file` is a Windows path starting with %DOCUMENTS% (the prefix user's
/// Documents) or %INSTALLDIR%; `value` may use %SCREEN_WIDTH% and %SCREEN_HEIGHT%.
struct IniSetting: Codable, Hashable {
    var file: String
    var section: String
    var key: String
    var value: String

    var fileName: String { CompatAction.fileName(file) }

    func targets(_ other: IniSetting) -> Bool {
        file.caseInsensitiveCompare(other.file) == .orderedSame && section.caseInsensitiveCompare(other.section) == .orderedSame
            && key.caseInsensitiveCompare(other.key) == .orderedSame
    }
}

/// An .ini change notwindows made. Games create most of their .ini files on first run, so a change to a file that
/// doesn't exist yet waits and is applied before each launch until it lands.
struct IniEdit: Codable, Hashable, Identifiable {
    var id = UUID()
    var setting: IniSetting
    var isPending = true
}

struct GameSettings: Codable, Hashable {
    // Graphics
    var direct3DBackend: Direct3DBackend = .dxmt
    var direct3D9Backend: Direct3D9Backend = .d9vk
    var cncDDraw = true
    var vulkanDriver: VulkanDriver = .platformDefault
    var dxvkVersion: DXVKVersion = .automatic
    var dxvkAsync = true
    var dxvkHUD: DXVKHUD = .off
    var metalHUD = false
    var moltenVKFastMath = false
    var retinaMode = false
    var fontSmoothing = false

    // Performance
    var msync = true
    var esync = true
    var advertiseAVX = true
    var wineRosetta = false
    var rosettaX87 = false

    // Input
    var commandAsControl = false
    var optionAsAlt = false
    var disableMFiControllers = true

    // System
    var windowsVersion: WindowsVersion = .win10
    var logLevel: WineLogLevel = .off
    var skipMono = false
    var skipGecko = false
    var dllOverrides: [DLLOverride] = []
    var environment: [EnvironmentVariable] = []
    var iniEdits: [IniEdit] = []

    init() {}

    /// Values written into the prefix registry; launching compares this against what was last applied.
    var registryFingerprint: String {
        [retinaMode, fontSmoothing, commandAsControl, optionAsAlt].map { $0 ? "1" : "0" }.joined()
            + windowsVersion.rawValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameSettings()
        direct3DBackend = (try? c.decodeIfPresent(Direct3DBackend.self, forKey: .direct3DBackend)) ?? d.direct3DBackend
        direct3D9Backend = (try? c.decodeIfPresent(Direct3D9Backend.self, forKey: .direct3D9Backend)) ?? d.direct3D9Backend
        cncDDraw = (try? c.decodeIfPresent(Bool.self, forKey: .cncDDraw)) ?? d.cncDDraw
        vulkanDriver = (try? c.decodeIfPresent(VulkanDriver.self, forKey: .vulkanDriver)) ?? d.vulkanDriver
        dxvkVersion = (try? c.decodeIfPresent(DXVKVersion.self, forKey: .dxvkVersion)) ?? d.dxvkVersion
        dxvkAsync = (try? c.decodeIfPresent(Bool.self, forKey: .dxvkAsync)) ?? d.dxvkAsync
        dxvkHUD = (try? c.decodeIfPresent(DXVKHUD.self, forKey: .dxvkHUD)) ?? d.dxvkHUD
        metalHUD = (try? c.decodeIfPresent(Bool.self, forKey: .metalHUD)) ?? d.metalHUD
        moltenVKFastMath = (try? c.decodeIfPresent(Bool.self, forKey: .moltenVKFastMath)) ?? d.moltenVKFastMath
        retinaMode = (try? c.decodeIfPresent(Bool.self, forKey: .retinaMode)) ?? d.retinaMode
        fontSmoothing = (try? c.decodeIfPresent(Bool.self, forKey: .fontSmoothing)) ?? d.fontSmoothing
        msync = (try? c.decodeIfPresent(Bool.self, forKey: .msync)) ?? d.msync
        esync = (try? c.decodeIfPresent(Bool.self, forKey: .esync)) ?? d.esync
        advertiseAVX = (try? c.decodeIfPresent(Bool.self, forKey: .advertiseAVX)) ?? d.advertiseAVX
        wineRosetta = (try? c.decodeIfPresent(Bool.self, forKey: .wineRosetta)) ?? d.wineRosetta
        rosettaX87 = (try? c.decodeIfPresent(Bool.self, forKey: .rosettaX87)) ?? d.rosettaX87
        commandAsControl = (try? c.decodeIfPresent(Bool.self, forKey: .commandAsControl)) ?? d.commandAsControl
        optionAsAlt = (try? c.decodeIfPresent(Bool.self, forKey: .optionAsAlt)) ?? d.optionAsAlt
        disableMFiControllers = (try? c.decodeIfPresent(Bool.self, forKey: .disableMFiControllers)) ?? d.disableMFiControllers
        windowsVersion = (try? c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion)) ?? d.windowsVersion
        logLevel = (try? c.decodeIfPresent(WineLogLevel.self, forKey: .logLevel)) ?? d.logLevel
        skipMono = (try? c.decodeIfPresent(Bool.self, forKey: .skipMono)) ?? d.skipMono
        skipGecko = (try? c.decodeIfPresent(Bool.self, forKey: .skipGecko)) ?? d.skipGecko
        dllOverrides = (try? c.decodeIfPresent([DLLOverride].self, forKey: .dllOverrides)) ?? d.dllOverrides
        environment = (try? c.decodeIfPresent([EnvironmentVariable].self, forKey: .environment)) ?? d.environment
        iniEdits = (try? c.decodeIfPresent([IniEdit].self, forKey: .iniEdits)) ?? d.iniEdits
    }
}
