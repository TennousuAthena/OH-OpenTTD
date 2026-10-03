#!/usr/bin/env python3
"""Prepare the actual game's rawfile resources for a DevEco/Hvigor build."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import zipfile

REPO = Path(__file__).resolve().parents[2]
PACKAGES = [
    {
        "name": "OpenGFX2_Classic-0.8.1.tar",
        "url": "https://github.com/OpenTTD/OpenGFX2/releases/download/0.8.1/OpenGFX2_Classic-0.8.1.tar",
        "sha256": "2f4d0d8cd82b9b15d7c5a742581bfd11a08d4fd54fc0743f1f8a1032e3b5eeaf",
    },
    {
        "name": "opensfx-1.0.3-all.zip",
        "url": "https://cdn.openttd.org/opensfx-releases/1.0.3/opensfx-1.0.3-all.zip",
        "sha256": "e0a218b7dd9438e701503b0f84c25a97c1c11b7c2f025323fb19d6db16ef3759",
    },
    {
        "name": "openmsx-0.4.2-all.zip",
        "url": "https://cdn.openttd.org/openmsx-releases/0.4.2/openmsx-0.4.2-all.zip",
        "sha256": "5a4277a2e62d87f2952ea5020dc20fb2f6ffafdccf9913fbf35ad45ee30ec762",
    },
    {
        "name": "timgm6mb-soundfont_1.3.orig.tar.gz",
        "url": "https://deb.debian.org/debian/pool/main/t/timgm6mb-soundfont/timgm6mb-soundfont_1.3.orig.tar.gz",
        "sha256": "af8f3a00e416dfb262bcaa904a1c84df04a51b72bbc1313aed012bc754bdf99b",
    },
]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download(package, cache):
    dest = cache / package["name"]
    if not dest.exists() or digest(dest) != package["sha256"]:
        partial = dest.with_name(dest.name + ".download")
        print(f"Downloading {package['name']}", flush=True)
        subprocess.run(["curl", "-fL", "--retry", "2", "--max-time", "180",
                        package["url"], "-o", str(partial)], check=True)
        if digest(partial) != package["sha256"]:
            partial.unlink()
            raise RuntimeError(f"SHA256 mismatch: {package['name']}")
        partial.replace(dest)
    print(f"Verified {package['name']}: {package['sha256']}", flush=True)
    return dest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strgen", type=Path, default=REPO / "build/host-tools/strgen")
    sdk = Path(os.environ.get("DEVECO_SDK_HOME", "/Applications/DevEco-Studio.app/Contents/sdk/default"))
    native = sdk / "openharmony/native" if (sdk / "openharmony/native").exists() else sdk / "native"
    parser.add_argument("--cmake", type=Path, default=native / "build-tools/cmake/bin/cmake")
    args = parser.parse_args()
    if not args.strgen.is_file():
        raise RuntimeError("Build the host strgen tool before staging resources")
    cache = REPO / "build/harmonyos/assets-cache"
    cache.mkdir(parents=True, exist_ok=True)
    archives = [download(package, cache) for package in PACKAGES]
    rawfile = REPO / "harmonyos/entry/src/main/resources/rawfile"
    stage = rawfile.with_name("rawfile.next")
    if stage.exists():
        shutil.rmtree(stage)
    (stage / "baseset").mkdir(parents=True)
    (stage / "lang").mkdir()
    (stage / "docs").mkdir()
    language_sources = sorted(source for source in (REPO / "src/lang").glob("*.txt")
                              if source.name != "CMakeLists.txt")
    for source in (REPO / "media/baseset").iterdir():
        if source.is_file() and source.suffix in {".grf", ".dat", ".ttf", ".obg", ".obm", ".obs"}:
            destination = stage / "baseset" / source.name
            if source.suffix in {".obg", ".obm", ".obs"}:
                # Use the upstream CMake generator for translations and GRF hashes.
                subprocess.run([str(args.cmake), f"-DBASESET_SOURCE_FILE={source}",
                                f"-DBASESET_BINARY_FILE={destination}",
                                f"-DBASESET_EXTRAGRF_FILE={REPO / 'media/baseset/orig_extra.grf'}",
                                "-P", str(REPO / "cmake/scripts/Baseset.cmake"), "--",
                                *map(str, language_sources)], check=True)
            else:
                shutil.copy2(source, destination)
    for archive in archives:
        if archive.name == "timgm6mb-soundfont_1.3.orig.tar.gz":
            with tarfile.open(archive, "r:gz") as bundle:
                member = bundle.getmember("timgm6mb-soundfont_1.3/TimGM6mb.sf2")
                if not member.isfile():
                    raise RuntimeError("Expected a regular TimGM6mb.sf2 file")
                with bundle.extractfile(member) as stream:
                    (stage / "baseset/TimGM6mb.sf2").write_bytes(stream.read())
        elif archive.suffix == ".tar":
            shutil.copy2(archive, stage / "baseset" / archive.name)
        else:
            with zipfile.ZipFile(archive) as bundle:
                members = [name for name in bundle.namelist() if name.endswith(".tar")]
                if len(members) != 1:
                    raise RuntimeError(f"Expected one baseset tar inside {archive.name}")
                member = members[0]
                contents = bundle.read(member)
                if archive.name.startswith("openmsx-"):
                    # MusicSet deliberately does not search tar archives. Keep
                    # the official directory and all its notices as real files.
                    with tarfile.open(fileobj=io.BytesIO(contents)) as music:
                        for entry in music.getmembers():
                            path = Path(entry.name)
                            if path.is_absolute() or ".." in path.parts:
                                raise RuntimeError(f"Unsafe music archive path: {entry.name}")
                            target = stage / "baseset" / path
                            if entry.isdir():
                                target.mkdir(parents=True, exist_ok=True)
                            elif entry.isfile():
                                target.parent.mkdir(parents=True, exist_ok=True)
                                with music.extractfile(entry) as stream:
                                    target.write_bytes(stream.read())
                            else:
                                raise RuntimeError(f"Unsupported music archive entry: {entry.name}")
                else:
                    # Graphics and sounds can read their official tar directly.
                    (stage / "baseset" / Path(member).name).write_bytes(contents)
    for source in language_sources:
        subprocess.run([str(args.strgen), "-s", str(REPO / "src/lang"),
                        "-d", str(stage / "lang"), str(source)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    for name in ["COPYING.md", "README.md"]:
        shutil.copy2(REPO / name, stage / "docs" / name)
        # HelpWindow searches these manuals in BASE_DIR, not DOCS_DIR.
        shutil.copy2(REPO / name, stage / name)
    # The dedicated port statement is opened from HelpWindow's Documents panel.
    port_docs = stage / "docs/harmonyos"
    port_docs.mkdir(parents=True)
    for name in ["port-statement.md", "port-notes.md", "port-guide.md", "performance.md"]:
        shutil.copy2(REPO / "docs/harmonyos" / name, port_docs / name)
    synth_notices = stage / "docs/runtime-libraries/tinysoundfont"
    synth_notices.mkdir(parents=True)
    for name in ["LICENSE", "README.md", "provenance.json", "TimGM6mb-NOTICE.txt"]:
        shutil.copy2(REPO / "src/3rdparty/tinysoundfont" / name, synth_notices / name)
    # Runtime libraries are statically linked into both game engines.
    # Preserve their notices with the game data, including ABI provenance.
    for abi in ["arm64-v8a", "x86_64"]:
        licenses = REPO / "build/harmonyos/runtime-deps" / abi / "share/licenses"
        if licenses.is_dir():
            shutil.copytree(licenses, stage / "docs/runtime-libraries" / abi)
    (stage / "docs/runtime-libraries.md").write_text(
        "# Native runtime libraries\n\n"
        "This software includes code from XZ Utils (https://tukaani.org/xz/) "
        "FreeType (https://freetype.org/) and TinySoundFont "
        "(https://github.com/schellingb/TinySoundFont). "
        "TimGM6mb is included as its GPLv2 General MIDI SoundFont.\n\n"
        "The bundled build records and license texts are in runtime-libraries/. "
        "Base graphics and sounds retain notices in their archives; "
        "OpenMSX music retains notices in its extracted baseset directory.\n",
        encoding="utf-8")
    files = sorted(path.relative_to(stage).as_posix() for path in stage.rglob("*") if path.is_file())
    hashes = {name: digest(stage / name) for name in files}
    version = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    manifest = {"version": version, "files": files, "sha256": hashes, "packages": PACKAGES}
    (stage / "openttd-assets.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if rawfile.exists():
        if any(rawfile.iterdir()) and not (rawfile / "openttd-assets.json").exists():
            raise RuntimeError("Existing rawfile contents have no generated manifest; preserve them before staging")
        shutil.rmtree(rawfile)
    stage.replace(rawfile)
    print(f"Staged {len(files)} game files ({version[:12]}) in {rawfile}")


if __name__ == "__main__":
    main()
