# rosettax87

Prebuilt `runtime_loader` and `libRuntimeRosettax87` from
[alicin/rosettax87_jit](https://github.com/alicin/rosettax87_jit) at commit `bf4ac51`,
a fork of [Lifeisawful/rosettax87_jit](https://github.com/Lifeisawful/rosettax87_jit) (MIT, see LICENSE) with build fixes
for newer Apple clang. The translator must stay unoptimized; an optimized build emits wrong x87 code.

notwindows copies these to `Tools/rosettax87`, signs the loader with `entitlements.plist` (it needs the debugger
entitlement to patch Rosetta inside the game process), and points Wine's `ROSETTA_X87_PATH` hook at it.

Rebuild:

```bash
git clone --recursive https://github.com/alicin/rosettax87_jit
```

```bash
cd rosettax87_jit && cmake -B build && cmake --build build --target runtime_loader libRuntimeRosettax87
```
