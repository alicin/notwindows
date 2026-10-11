# rosettax87

Prebuilt `runtime_loader` and `libRuntimeRosettax87` from
[alicin/rosettax87_jit](https://github.com/alicin/rosettax87_jit/tree/build-fix-apple-clang) at commit `68f79f9`,
a fork of [Lifeisawful/rosettax87_jit](https://github.com/Lifeisawful/rosettax87_jit) (MIT, see LICENSE) with a build fix
for newer Apple clang.

notwindows copies these to `Tools/rosettax87`, signs the loader with `entitlements.plist` (it needs the debugger
entitlement to patch Rosetta inside the game process), and points Wine's `ROSETTA_X87_PATH` hook at it.

Rebuild:

```bash
git clone --recursive -b build-fix-apple-clang https://github.com/alicin/rosettax87_jit
```

```bash
cd rosettax87_jit && cmake -B build && cmake --build build --target runtime_loader libRuntimeRosettax87
```
