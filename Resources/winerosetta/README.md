# winerosetta.dll

Prebuilt 32-bit `winerosetta.dll` from [Sikarugir-App/winerosetta](https://github.com/Sikarugir-App/winerosetta)
at commit `d0109981f89713d99905c154a160b00d4acc34cd`, MIT licensed.

It emulates instructions Rosetta 2 can't run in 32-bit World of Warcraft clients (1.12.1, 2.4.3, 3.3.5a) and
forwards `Direct3DCreate9` to `d9vk.dll` when present, otherwise to the system `d3d9.dll`.

Rebuild with Homebrew's `mingw-w64`:

```bash
i686-w64-mingw32-g++ -std=c++20 -O2 -s -shared -static -static-libgcc -static-libstdc++ \
  -fno-exceptions -fno-unwind-tables -Wl,--enable-stdcall-fixup \
  -o winerosetta.dll src/winerosetta.cpp src/winerosetta.def -lshell32 -lole32 -luuid
```
