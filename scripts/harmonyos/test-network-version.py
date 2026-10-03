#!/usr/bin/env python3
"""Exercise generated release metadata with the real network version functions."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
CMAKE = os.environ.get("CMAKE", shutil.which("cmake") or "cmake")
CXX = os.environ.get("CXX", "c++")


def generate(destination, harmonyos, major=15):
    return subprocess.run([
        CMAKE, f"-DFIND_VERSION_BINARY_DIR={destination}",
        f"-DCPACK_BINARY_DIR={destination}", f"-DREV_MAJOR={major}",
        "-DREV_MINOR=3", f"-DHARMONYOS={'ON' if harmonyos else 'OFF'}",
        "-P", str(REPO / "cmake/scripts/FindVersion.cmake"),
    ], cwd=REPO, capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory(prefix="openttd-network-version-") as temporary:
        work = Path(temporary)
        result = generate(work / "port", True)
        assert result.returncode == 0, result.stdout + result.stderr
        port = (work / "port/rev.cpp").read_text()
        assert 'const std::string _openttd_revision = "15.3";' in port
        assert 'const std::string _openttd_revision_display = "15.3-harmonyos.2";' in port
        assert "const uint8_t _openttd_revision_tagged = 1;" in port
        source_hash = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()
        assert f'_openttd_revision_hash = "{source_hash}";' in port

        result = generate(work / "desktop", False)
        assert result.returncode == 0, result.stdout + result.stderr
        desktop = (work / "desktop/rev.cpp").read_text()
        version = re.search(r'_openttd_revision = "([^"]+)";', desktop)[1]
        assert f'_openttd_revision_display = "{version}";' in desktop
        assert "harmonyos." not in version
        mismatch = generate(work / "mismatch", True, major=16)
        assert mismatch.returncode != 0 and "baseline does not match" in mismatch.stderr

        # Compile the production functions, rather than a separate model of
        # them, against the actual CMake-generated constants.
        network = (REPO / "src/network/core/network_game_info.cpp").read_text()
        start = network.index("std::string_view GetNetworkRevisionString()")
        end = network.index("void CheckGameCompatibility", start)
        constants = "\n".join(line for line in port.splitlines() if line.startswith("const "))
        harness = '''
#include <cassert>
#include <string>
#include <string_view>
#define FMT_HEADER_ONLY
#include <fmt/format.h>
#define NETWORK_INTERNAL_H
#define Debug(...)
static const unsigned NETWORK_REVISION_LENGTH = 33;
static const unsigned GITHASH_SUFFIX_LEN = 12;
'''
        harness += constants + "\n" + network[start:end]
        harness += '''
int main() {
#ifdef NETWORK_SEND_DOUBLE_SEED
    const std::string expected = "dbg_seed-15.3";
#elif defined(ENABLE_NETWORK_SYNC_EVERY_FRAME)
    const std::string expected = "dbg_sync-15.3";
#else
    const std::string expected = "15.3";
#endif
    assert(GetNetworkRevisionString() == expected);
    assert(IsNetworkCompatibleVersion(expected));
    assert(!IsNetworkCompatibleVersion("15.2"));
    assert(!IsNetworkCompatibleVersion("16.0"));
    assert(!IsNetworkCompatibleVersion("15.3-harmonyos.2"));
    assert(!IsNetworkCompatibleVersion("20260820-harmonyos-port-m8e457981b6"));
    assert(_openttd_newgrf_version == 0x1f386d64);
#ifdef ENABLE_NETWORK_SYNC_EVERY_FRAME
    assert(!IsNetworkCompatibleVersion("15.3"));
#else
    assert(!IsNetworkCompatibleVersion("dbg_sync-15.3"));
    assert(!IsNetworkCompatibleVersion("dbg_seed-15.3"));
#endif
}
'''
        source = work / "version.cpp"
        source.write_text(harness)
        flags = subprocess.check_output(["pkg-config", "--cflags", "fmt"], text=True).split()
        for name, defines in [("release", []), ("sync", ["-DENABLE_NETWORK_SYNC_EVERY_FRAME"]),
                              ("seed", ["-DENABLE_NETWORK_SYNC_EVERY_FRAME", "-DNETWORK_SEND_DOUBLE_SEED"])]:
            binary = work / name
            subprocess.run([CXX, "-std=c++20", *flags, *defines, str(source), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
            print(f"PASS: {name} compatibility, version mismatch rejection, NewGRF release bit")

        app = json.loads((REPO / "harmonyos/AppScope/app.json5").read_text())["app"]
        assert app["versionName"] == "15.3-harmonyos.2"
        assert app["versionCode"] == 15000302
        print("PASS: native display, app release, desktop behavior, baseline guard and source provenance")


if __name__ == "__main__":
    main()
