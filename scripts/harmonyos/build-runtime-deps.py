#!/usr/bin/env python3
"""Build pinned native runtime libraries for both HarmonyOS ABIs."""

import argparse
import hashlib
import json
import shutil
import subprocess
import tarfile
from pathlib import Path


def main() -> None:
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dep', choices=('liblzma', 'freetype'), default='liblzma')
    parser.add_argument('--sdk-root', type=Path, required=True,
                        help='DevEco SDK root containing openharmony/native and hms/native')
    parser.add_argument('--cache', type=Path, default=repo / 'build/harmonyos/deps-cache')
    args = parser.parse_args()
    sdk = args.sdk_root.resolve()
    native = sdk / 'openharmony/native'
    hms = sdk / 'hms/native'
    metadata = json.loads((native / 'oh-uni-package.json').read_text())
    if metadata['apiVersion'] != '26':
        raise SystemExit('This build recipe requires the verified API 26 SDK.')
    manifest = json.loads((repo / 'harmonyos/dependencies/manifest.json').read_text())
    dep = next(d for d in manifest['dependencies'] if d['id'] == args.dep)
    archive = args.cache / dep['archive']
    with archive.open('rb') as handle:
        digest = hashlib.file_digest(handle, 'sha256').hexdigest()
    if digest != dep['sha256']:
        raise SystemExit(f'SHA256 mismatch for {archive.name}')

    work = repo / 'build/harmonyos'
    sources = work / 'runtime-sources'
    sources.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as package:
        source = sources / package.getnames()[0].split('/')[0]
        if not source.exists():
            package.extractall(sources, filter='data')
    cmake = native / 'build-tools/cmake/bin/cmake'
    ninja = native / 'build-tools/cmake/bin/ninja'
    for abi in ('arm64-v8a', 'x86_64'):
        build = work / 'runtime-build' / abi / args.dep
        prefix = work / 'runtime-deps' / abi
        command = [str(cmake), '-S', str(source), '-B', str(build), '-G', 'Ninja',
                   f'-DCMAKE_MAKE_PROGRAM={ninja}',
                   f'-DCMAKE_TOOLCHAIN_FILE={repo / "cmake/HarmonyOSNativeToolchain.cmake"}',
                   f'-DHARMONYOS_SDK_TOOLCHAIN_FILE={hms / "build/cmake/hmos.toolchain.cmake"}',
                   f'-DOHOS_SDK_NATIVE={native}', f'-DHMOS_SDK_NATIVE={hms}',
                   f'-DOHOS_ARCH={abi}', '-DOHOS_PLATFORM_LEVEL=1',
                   '-DOHOS_SDK_NATIVE_PLATFORM=ohos-1', '-DOHOS_STL=c++_shared',
                   '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
                   f'-DCMAKE_INSTALL_PREFIX={prefix}', '-DCMAKE_INSTALL_LIBDIR=lib',
                   '-DBUILD_SHARED_LIBS=OFF']
        if args.dep == 'liblzma':
            command += ['-DENABLE_NLS=OFF', '-DENABLE_SANDBOX=OFF']
        else:
            command += ['-DFT_DISABLE_HARFBUZZ=ON', '-DFT_DISABLE_BROTLI=ON',
                        '-DFT_DISABLE_BZIP2=ON', '-DFT_DISABLE_PNG=ON']
        subprocess.run(command, check=True)
        subprocess.run([str(cmake), '--build', str(build), '--target', args.dep,
                        '--parallel', '4'], check=True)
        install = [str(cmake), '--install', str(build)]
        if args.dep == 'liblzma':
            install += ['--component', 'liblzma_Development']
        subprocess.run(install, check=True)
        licenses = prefix / 'share/licenses' / args.dep
        licenses.mkdir(parents=True, exist_ok=True)
        license_files = ['COPYING', 'COPYING.0BSD'] if args.dep == 'liblzma' else ['docs/FTL.TXT', 'docs/GPLv2.TXT', 'LICENSE.TXT']
        for filename in license_files:
            shutil.copy2(source / filename, licenses / Path(filename).name)
        provenance = {'id': dep['id'], 'version': dep['version'], 'sha256': digest,
                      'abi': abi, 'sdkVersion': metadata['version']}
        (licenses / 'build.json').write_text(json.dumps(provenance, indent=2) + '\n')
        print(f'Built {args.dep} {dep["version"]} for {abi}', flush=True)


if __name__ == '__main__':
    main()
