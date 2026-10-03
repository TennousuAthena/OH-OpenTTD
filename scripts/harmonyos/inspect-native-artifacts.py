#!/usr/bin/env python3
"""Verify the packaged game, its effective compiler flags, and matching symbols."""

import argparse
import hashlib
import json
import mmap
from pathlib import Path
import re
import shlex
import shutil
import struct
import zipfile


def elf_metadata(data):
    if data[:6] != b'\x7fELF\x02\x01':
        raise ValueError('expected a little-endian 64-bit ELF library')
    machine = struct.unpack_from('<H', data, 18)[0]
    offset = struct.unpack_from('<Q', data, 40)[0]
    size, count, strings_index = struct.unpack_from('<HHH', data, 58)
    strings_offset = struct.unpack_from('<Q', data, offset + strings_index * size + 24)[0]
    sections = {}
    for index in range(count):
        start = offset + index * size
        name_offset = strings_offset + struct.unpack_from('<I', data, start)[0]
        end = data.find(b'\0', name_offset)
        name = data[name_offset:end].decode('ascii')
        sections[name] = struct.unpack_from('<QQ', data, start + 24)
    build_id = None
    if '.note.gnu.build-id' in sections:
        start, length = sections['.note.gnu.build-id']
        names, desc, kind = struct.unpack_from('<III', data, start)
        if kind == 3 and data[start + 12:start + 12 + names].rstrip(b'\0') == b'GNU':
            begin = start + 12 + ((names + 3) & ~3)
            build_id = data[begin:begin + desc].hex()
    return {'buildId': build_id, 'machine': machine,
            'debugSymbols': '.debug_info' in sections,
            'textBytes': sections.get('.text', (0, 0))[1]}


def file_metadata(path):
    with path.open('rb') as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
        return elf_metadata(data)


def compile_policy(path, allow_unoptimized, targets):
    entries = json.loads(path.read_text())
    target_pattern = re.compile(r'CMakeFiles/(?:' + '|'.join(map(re.escape, targets)) + r')\.dir/')
    entries = [entry for entry in entries
               if target_pattern.search(entry.get('command', ' '.join(entry.get('arguments', []))))]
    if not entries:
        raise ValueError('compile database has no native runtime translation units')
    optimization = set()
    perf = False
    for entry in entries:
        arguments = entry.get('arguments') or shlex.split(entry['command'])
        flags = [flag for flag in arguments if re.fullmatch(r'-O(?:[0-3sgz]|fast)?', flag)]
        effective = flags[-1] if flags else '-O0'
        if effective != '-O2' and not (allow_unoptimized and effective == '-O0'):
            raise ValueError(f'{Path(entry["file"]).name}: effective optimization is {effective}, expected -O2')
        if '-g' not in arguments:
            raise ValueError(f'{Path(entry["file"]).name}: debug symbols not requested')
        optimization.add(effective)
        perf |= '-DOPENTTD_HARMONYOS_PERF' in arguments
    return {'effectiveOptimization': sorted(optimization), 'debugSymbols': True,
            'performanceDiagnostics': perf, 'translationUnits': len(entries),
            'compileDatabaseSha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hap', required=True, type=Path)
    parser.add_argument('--native-build-root', required=True, type=Path,
                        help='Hvigor .cxx/default/default/debug or release directory')
    parser.add_argument('--native-objects', type=Path,
                        default=Path(__file__).resolve().parents[2] / 'harmonyos/entry/build/default/intermediates/cmake/default/obj')
    parser.add_argument('--symbols-dir', type=Path, help='Copy verified unstripped libraries here')
    parser.add_argument('--output', type=Path, help='Write a native build manifest without machine paths')
    parser.add_argument('--allow-unoptimized', action='store_true', help='Allow a deliberate -O0 Debug baseline')
    args = parser.parse_args()
    with args.hap.open('rb') as handle:
        report = {'abis': {}, 'hapSha256': hashlib.file_digest(handle, 'sha256').hexdigest()}
    symbol_files = []
    with zipfile.ZipFile(args.hap) as hap:
        app = json.loads(hap.read('module.json'))['app']
        if args.allow_unoptimized and app.get('buildMode') != 'debug':
            raise ValueError('unoptimized artifacts must use Debug build mode')
        report['app'] = {key: app[key] for key in ('bundleName', 'versionName', 'versionCode',
                                                 'buildMode', 'targetAPIVersion', 'minAPIVersion')}
        for abi, machine in (('arm64-v8a', 183), ('x86_64', 62)):
            build = args.native_build_root / abi
            result = {'host': compile_policy(build / 'compile_commands.json', args.allow_unoptimized, ('entry',)),
                      'engine': compile_policy(build / 'openttd-engine/compile_commands.json', args.allow_unoptimized, ('openttd_lib', 'openttd')),
                      'libraries': {}}
            for library in ('libentry.so', 'libopenttd.so'):
                packaged = hap.read(f'libs/{abi}/{library}')
                packaged_info = elf_metadata(packaged)
                symbols = args.native_objects / abi / library
                symbol_info = file_metadata(symbols)
                if packaged_info['machine'] != machine or symbol_info['machine'] != machine:
                    raise ValueError(f'{abi}/{library}: wrong ELF architecture')
                if not packaged_info['buildId'] or packaged_info['buildId'] != symbol_info['buildId']:
                    raise ValueError(f'{abi}/{library}: packaged and unstripped Build IDs differ')
                if not symbol_info['debugSymbols']:
                    raise ValueError(f'{abi}/{library}: unstripped debug symbols are missing')
                if library == 'libopenttd.so':
                    engine_info = file_metadata(build / 'openttd-engine/libopenttd.so')
                    if engine_info['buildId'] != packaged_info['buildId']:
                        raise ValueError(f'{abi}: HAP contains a different engine build')
                    if packaged_info['textBytes'] < 1024 * 1024:
                        raise ValueError(f'{abi}: packaged engine appears to be the old scaffold')
                    if not args.allow_unoptimized and b'Native build: optimized (-O2), debug symbols retained' not in packaged:
                        raise ValueError(f'{abi}: packaged engine is missing the optimized-build capability marker')
                result['libraries'][library] = {
                    'buildId': packaged_info['buildId'], 'debugSymbolsRetained': True,
                    'packagedBytes': len(packaged), 'packagedSha256': hashlib.sha256(packaged).hexdigest()}
                symbol_files.append((abi, symbols))
            report['abis'][abi] = result
    if args.symbols_dir:
        build_ids = {}
        for abi, source in symbol_files:
            destination = args.symbols_dir / abi / source.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            build_ids.setdefault(abi, {})[source.name] = report['abis'][abi]['libraries'][source.name]['buildId']
        (args.symbols_dir / 'buildid-map.json').write_text(json.dumps({'buildId': build_ids}, indent=2) + '\n')
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'result': 'PASS', 'abis': list(report['abis']),
                      'effectiveOptimization': {abi: value['engine']['effectiveOptimization']
                                                for abi, value in report['abis'].items()}}))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        raise SystemExit(f'Native artifact check failed: {error}')
