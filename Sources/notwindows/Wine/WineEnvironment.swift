import Foundation

/// Builds the process environment for a Wine invocation, mirroring what Sikarugir's wrapper launcher exports
/// but driven by per-game settings instead of a wrapper's Info.plist.
enum WineEnvironment {
    static func make(
        engine: Engine,
        runtime: Runtime,
        prefix: URL,
        settings: GameSettings,
        cacheDirectory: URL? = nil,
        extraDLLOverrides: [String] = [],
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "__CF_USER_TEXT_ENCODING", "SSH_AUTH_SOCK"] {
            if let value = base[key] { env[key] = value }
        }
        env["LANG"] = base["LANG"] ?? "en_US.UTF-8"

        env["WINEPREFIX"] = prefix.path
        env["CX_ROOT"] = engine.bundle.path
        env["PATH"] = [engine.bin.path, runtime.tools.path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["WINEDLLPATH"] = ["x86_64-windows", "i386-windows", "x86_64-unix"]
            .map { engine.wineLib.appendingPathComponent($0).path }
            .joined(separator: ":")
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [
            engine.lib.path,
            runtime.frameworks.path,
            runtime.gstreamerLibraries.path,
            "/opt/wine/lib", "/usr/lib", "/usr/libexec", "/usr/lib/system",
        ].joined(separator: ":")
        env["GST_PLUGIN_PATH"] = runtime.gstreamerLibraries.appendingPathComponent("gstreamer-1.0").path
        env["VK_DRIVER_FILES"] = runtime.icd(for: settings.vulkanDriver).path

        // Sikarugir's ntdll refuses to spawn child processes without this marker.
        env["SikarugirAppWine11"] = "1"
        env["WINEBOOT_HIDE_DIALOG"] = "1"
        env["WINEDEBUG"] = settings.logLevel.winedebug
        env["WINEMSYNC"] = settings.msync ? "1" : "0"
        env["WINEESYNC"] = settings.esync ? "1" : "0"
        if settings.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        env["FEX_X87REDUCEDPRECISION"] = "1"
        env["DOTNET_EnableWriteXorExecute"] = "0"
        env["CX_FWD_COMPAT_GL_CTX"] = "1"
        env["QMLSCENE_DEVICE"] = "softwarecontext"
        env["SDL_JOYSTICK_MFI"] = settings.disableMFiControllers ? "0" : "1"

        env["MTL_HUD_ENABLED"] = settings.metalHUD ? "1" : "0"
        env["MVK_CONFIG_FAST_MATH_ENABLED"] = settings.moltenVKFastMath ? "1" : "0"
        env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"

        let d3dmetalExternal = runtime.renderer("d3dmetal").appendingPathComponent("external")
        let libd3dshared = d3dmetalExternal.appendingPathComponent("libd3dshared.dylib").path
        env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = libd3dshared
        env["CX_APPLEGPT_LIBD3DSHARED_PATH"] = libd3dshared

        func rendererPath(_ name: String) -> String { runtime.renderer(name).appendingPathComponent("wine").path }

        switch settings.direct3DBackend {
        case .wined3d:
            break
        case .dxmt:
            env["WINEDLLPATH_DXMT"] = rendererPath("dxmt")
            env["WINEDLLPATH_PREPEND"] = rendererPath("dxmt")
            env["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"] = "1"
        case .dxvk:
            env["WINEDLLPATH_DXVK"] = rendererPath(dxvkRendererName(for: settings))
        case .d3dmetal:
            env["WINEDLLPATH_D3DMETAL"] = rendererPath("d3dmetal")
            env["CX_D3DMETALPATH"] = d3dmetalExternal.path
        }

        if settings.direct3DBackend == .dxvk || settings.direct3D9Backend == .d9vk {
            env["DXVK_ASYNC"] = settings.dxvkAsync ? "1" : "0"
            if let hud = settings.dxvkHUD.envValue { env["DXVK_HUD"] = hud }
            if let cacheDirectory {
                env["DXVK_SHADER_CACHE_PATH"] = cacheDirectory.appendingPathComponent("dxvk").path
            }
        }
        if settings.direct3D9Backend == .d9vk { env["WINEDLLPATH_D9VK"] = rendererPath("d9vk") }
        if settings.cncDDraw { env["WINEDLLPATH_CNCD"] = rendererPath("cnc_ddraw") }

        var overrides = extraDLLOverrides
        // winerosetta sits next to the game as a native d3d9.dll.
        if settings.wineRosetta { overrides.append("d3d9=n,b") }
        if settings.skipMono { overrides.append("mscoree=") }
        if settings.skipGecko { overrides.append("mshtml=") }
        overrides += settings.dllOverrides
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.name.trimmingCharacters(in: .whitespaces))=\($0.mode.rawValue)" }
        if !overrides.isEmpty { env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";") }

        for variable in settings.environment where !variable.key.trimmingCharacters(in: .whitespaces).isEmpty {
            env[variable.key.trimmingCharacters(in: .whitespaces)] = variable.value
        }
        return env
    }

    static func dxvkRendererName(for settings: GameSettings) -> String {
        switch settings.dxvkVersion {
        case .legacy: "dxvk"
        case .modern: "dxvk3"
        case .automatic: settings.vulkanDriver == .kosmicKrisp ? "dxvk3" : "dxvk"
        }
    }
}
