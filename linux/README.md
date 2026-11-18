# Path of Building on Linux (native)

This fork runs Path of Building natively on Linux, without Wine. The Lua program in `src/` is the same as upstream
apart from a Linux-aware updater. The Windows engine (`Path of Building.exe` + `SimpleGraphic.dll`) is replaced by a
native build of SimpleGraphic, committed to `runtime/`:

| File                  | Purpose                                                      |
|-----------------------|--------------------------------------------------------------|
| `PathOfBuilding`      | Launcher: loads the engine and starts a Lua script           |
| `libSimpleGraphic.so` | The engine: window, rendering, input, fonts, Lua (LuaJIT)    |
| `lcurl.so`            | HTTPS for Lua (build imports, trade, updates)                |
| `lzip.so`             | Zip archive reading for Lua (used by the updater)            |
| `lua-utf8.so`         | UTF-8 string functions for Lua                               |
| `socket.so`           | Sockets for Lua (OAuth login callback)                       |

---

## For users

### Requirements

- 64-bit x86 Linux with **glibc 2.38 or newer** (Ubuntu 24.04+, Linux Mint 22+, Fedora 39+, Debian 13+, Arch)
- **OpenSSL 3** (`libssl.so.3`), installed by default on the distros above
- **OpenGL ES / EGL** libraries (`libGLESv2.so.2`, `libEGL.so.1`), which come with Mesa and the NVIDIA driver
- An X11 session. Wayland sessions run through XWayland, which has not been tested yet.

### Install

```bash
git clone https://github.com/grau-maus/PathOfBuilding-linux.git
cd PathOfBuilding-linux
linux/install.sh
```

This adds **Path of Building** to your application menu and a `path-of-building` command (in `~/.local/bin`). It
also registers PoB as the handler for `pob://` build links.

To remove it, run `linux/install.sh --uninstall`. Your builds are kept.

To try it without installing, run `./PathOfBuilding.sh` from the clone. This starts PoB in **Dev Mode**, which saves
builds inside the clone and never auto-updates.

### Where things are

| What                          | Where                                                       |
|-------------------------------|-------------------------------------------------------------|
| Program                       | `~/.local/opt/path-of-building/` (`POB_PREFIX` overrides it) |
| Builds and settings           | `~/.local/share/Path of Building/`                          |
| Window size/position, display | `~/.local/opt/path-of-building/SimpleGraphic/SimpleGraphic.cfg` |

### Updates

- **Program, data and passive trees** update automatically, as on Windows. They come from this fork's `master`
  branch (`POB_BRANCH` overrides it at install time).
- **The engine binaries are never auto-updated.** To get a new engine, pull and reinstall:
  ```bash
  git pull && linux/install.sh
  ```
  Reinstalling keeps your builds and settings.

### Troubleshooting

- **`version 'GLIBC_2.38' not found`**: your distro is older than the binaries support. Build the engine yourself
  (see [Building the engine](#building-the-engine)); a local build works on your glibc.
- **`libGLESv2.so.2: cannot open shared object file`**: install your distro's GLES package (`libgles2` on
  Debian/Ubuntu, `libglvnd-gles` on Fedora, `libglvnd` on Arch).
- **Console warnings about `PassiveMasteryConnectedButton.png`, `jewel-3.png` and `jewel-radius.png`** are normal.
  Upstream PoB doesn't ship those files either.
- To see the engine log, start PoB from a terminal (`path-of-building` or `./PathOfBuilding.sh`).
- Report Linux-specific problems to [this fork](https://github.com/grau-maus/PathOfBuilding-linux/issues), not to
  upstream PoB.

---

## For maintainers

### Building the engine

The engine source is the `master` branch of
[grau-maus/PathOfBuilding-SimpleGraphic](https://github.com/grau-maus/PathOfBuilding-SimpleGraphic). That is upstream
SimpleGraphic master plus its Linux port: upstream PR
[#98](https://github.com/PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic/pull/98), adapted to current upstream.

Build requirements: `cmake`, `gcc`/`g++` 13+, `pkg-config`, `git`, `curl`, `zip`, `unzip`, and the GL/X11 headers
(Debian/Ubuntu: `libgl-dev libegl-dev libgles-dev libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev`).
vcpkg fetches and statically links everything else.

```bash
linux/build-simplegraphic.sh [path/to/PathOfBuilding-SimpleGraphic]
```

- The checkout defaults to `../PathOfBuilding-SimpleGraphic` and is cloned from the fork if missing.
- The first build compiles all vcpkg dependencies, which takes several minutes. Later builds are incremental.
- The script installs **stripped** binaries into `runtime/`, ready to commit.

### The glibc baseline

A binary runs only on distros whose glibc is at least as new as the one it was built against. **The distro you
build on sets the minimum for every user.** The committed binaries were built on Linux Mint 22 (glibc 2.39) and need
glibc 2.38.

To check what a build requires before committing it:

```bash
objdump -T runtime/libSimpleGraphic.so | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1
```

If you raise it, update the requirements above. To support older distros, build inside an older distro, for example
an `ubuntu:22.04` container.

### Releasing a new engine build

1. Update the engine source (see [Keeping up with upstream](#keeping-up-with-upstream)).
2. Run `linux/build-simplegraphic.sh`.
3. Smoke-test with `./PathOfBuilding.sh`:
   - the passive tree renders;
   - a build imports from a link (this exercises HTTPS);
   - closing the window logs `Engine shutdown complete.`
4. Check the glibc baseline, then commit the six files in `runtime/`.

The `.so` files are deliberately left out of `manifest.xml` (see `manifest.cfg`), so the auto-updater never touches
them. Replacing a library PoB has loaded can crash it.

### How updates reach Linux installs

- **Where installs look:** `manifest.xml` points every install at
  `raw.githubusercontent.com/grau-maus/PathOfBuilding-linux/{branch}/`, where `{branch}` is `master`.
  `update_manifest.py` generates these URLs.
- **Linux filtering:** on Linux, `src/UpdateCheck.lua` skips every Windows binary (`runtime="win32"`, `.dll`,
  `.exe`). It downloads the remaining files. When the user clicks **Update Ready**, PoB applies them in place and
  restarts inside the same process.
- **Pushing to `master` ships to users.** Installed copies check for updates at launch and every 12 hours while
  open. Before pushing, regenerate the manifest:
  ```bash
  python3 update_manifest.py --in-place
  ```
  If the hashes in `manifest.xml` don't match the files on `master`, installs re-download the mismatched files on
  every check.

### Keeping up with upstream

This fork only exists to carry changes upstream doesn't have yet. If nobody keeps syncing it, it drifts in two
ways, and both are visible to users:

- **Program drift.** New leagues, skill data, trees and fixes reach upstream users but not Linux installs. That is a
  missing-features problem, not breakage.
- **Engine drift.** Sometimes upstream PoB's Lua starts depending on a newer SimpleGraphic. Upstream signals this with
  a commit like *"Update DLLs to SimpleGraphic-vX"* that changes `runtime/*.dll`. If such Lua reaches Linux users
  on the old engine, PoB can fail to start or error. Treat a DLL change in an upstream merge as **"rebuild the Linux
  engine in the same push"**.

**Syncing PoB** (this repo):

```bash
git remote add upstream https://github.com/PathOfBuildingCommunity/PathOfBuilding.git   # once
git fetch upstream
git checkout master && git merge upstream/master
```

1. **Resolve `manifest.xml` conflicts** by taking upstream's file. Expect a conflict on the `<Source>` lines every
   upstream release. Step 4 regenerates the file with this fork's URLs and current hashes anyway.
2. **Check whether the merge touched `src/UpdateCheck.lua`.** If it did, make sure the Linux handling survived:
   `windowsHost` and `skipFileOnHost`.
3. **Check whether the merge changed `runtime/*.dll`.** If it did, update the engine first (below).
4. **Run `python3 update_manifest.py --in-place`**, then smoke-test, then push.

**Syncing the engine** (the SimpleGraphic fork):

```bash
git remote add upstream https://github.com/PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic.git   # once
git fetch upstream
git checkout master && git merge upstream/master
git submodule update --init --recursive
```

Likely conflicts are in `vcpkg-configuration.json` and `vcpkg-ports/versions/baseline.json`:

- Keep the upstream baseline, and keep `angle`, `openssl` and `pthread-stubs` in it.
- If upstream added a new LuaJIT port version, carry the Linux changes into it: `006-fix-getenvcopy-linux.patch`,
  the `LUAJIT_ENABLE_GC64` flag, the `configure` chmod, and the `luajit` symlink fix in `portfile.cmake`.

Then build and smoke-test as above.

**Ways to reduce the maintenance:**

- **Get the changes accepted upstream.** Upstream PR #98 adds the Linux engine port. The `UpdateCheck.lua` change is
  small and harmless on Windows, so it would make a reasonable upstream PR too. Every change upstream accepts is one
  less thing this fork has to carry through each merge.
- **Automate the sync.** A scheduled GitHub Actions workflow could merge upstream weekly, regenerate the manifest and
  open a pull request. It could also flag when upstream's DLLs change, since that means the engine needs a rebuild.
  There is no such workflow yet.
