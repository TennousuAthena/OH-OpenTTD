#!/usr/bin/env python3
"""Compile the OpenTTD C++20 requirements with a selected OHOS SDK.

This checks the SDK alone, without the project's compatibility headers. It
does not link or run target code, and is not an engine or HAP build check.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import textwrap


TARGETS = {
    "arm64-v8a": "aarch64-linux-ohos",
    "x86_64": "x86_64-linux-ohos",
}

PROBES = {
    "concepts": """
        #include <concepts>
        template<std::integral T> constexpr T identity(T value) { return value; }
        static_assert(identity(3) == 3);
    """,
    "scalar_spaceship": """
        #include <compare>
        struct Value { int value; auto operator<=>(const Value&) const = default; };
        static_assert(Value{1} < Value{2});
    """,
    "implicit_typename": """
        struct Base { using ValueType = int; };
        template<class T> struct Derived : T {
            using BaseClass = T;
            using ValueType = BaseClass::ValueType;
            static constexpr int value(const BaseClass::ValueType& input) {
                return input;
            }
        };
        static_assert(Derived<Base>::value(3) == 3);
    """,
    "aggregate_paren_init": """
        struct Aggregate { int value; };
        constexpr Aggregate value(3);
        static_assert(value.value == 3);
    """,
    "aggregate_ctad": """
        struct Base { int& value; };
        template<class T> struct Aggregate : Base { T projection; };
        int value = 3;
        auto aggregate = Aggregate{{value}, 42};
    """,
    "ranges_count_if": """
        #include <algorithm>
        int probe() {
            int values[] = {1, 2, 3};
            return std::ranges::count_if(values, [](int value) { return value > 1; });
        }
    """,
    "ranges_lower_bound": """
        #include <algorithm>
        struct Item { int value; };
        int probe() {
            Item values[] = {{1}, {2}, {3}};
            return std::ranges::lower_bound(values, 2, std::less{}, &Item::value)->value;
        }
    """,
    "ranges_binary_search": """
        #include <algorithm>
        bool probe() {
            int values[] = {1, 2, 3};
            return std::ranges::binary_search(values, 2);
        }
    """,
    "array_spaceship": """
        #include <array>
        #include <compare>
        bool probe(const std::array<int, 2>& left, const std::array<int, 2>& right) {
            return (left <=> right) < 0;
        }
    """,
    "vector_spaceship": """
        #include <vector>
        #include <compare>
        bool probe(const std::vector<int>& left, const std::vector<int>& right) {
            return (left <=> right) < 0;
        }
    """,
    "string_spaceship": """
        #include <string>
        #include <compare>
        bool probe(const std::string& left, const std::string& right) {
            return (left <=> right) < 0;
        }
    """,
    "tuple_spaceship": """
        #include <tuple>
        #include <compare>
        bool probe(const std::tuple<int, int>& left, const std::tuple<int, int>& right) {
            return (left <=> right) < 0;
        }
    """,
    "source_location": """
        #include <source_location>
        constexpr auto location = std::source_location::current();
        static_assert(location.line() > 0);
    """,
}


def read_metadata(path):
    if not path.is_file():
        return None
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-root", type=Path, required=True,
                        help="SDK root containing native/ or openharmony/native/")
    parser.add_argument("--abi", choices=TARGETS, action="append",
                        help="target ABI; repeat to check both (default: arm64-v8a)")
    parser.add_argument("--output", type=Path, required=True,
                        help="directory for source files, compiler logs and report.json")
    args = parser.parse_args()

    sdk = args.sdk_root.expanduser().resolve()
    candidates = (sdk / "openharmony/native", sdk / "native")
    native = next((path for path in candidates
                   if (path / "llvm/bin/clang++").is_file()), None)
    if native is None:
        parser.error(f"no native SDK compiler found beneath {sdk}")
    sysroot = native / "sysroot"
    if not sysroot.is_dir():
        parser.error(f"missing SDK sysroot: {sysroot}")
    compiler = native / "llvm/bin/clang++"
    version = subprocess.run([str(compiler), "--version"], text=True,
                             capture_output=True, check=True).stdout.strip()
    metadata_command = [str(compiler), f"--target={TARGETS[(args.abi or ['arm64-v8a'])[0]]}",
                        f"--sysroot={sysroot}", "-std=c++20", "-dM", "-E", "-x", "c++",
                        "-include", "__config", "-"]
    metadata_result = subprocess.run(metadata_command, input="", text=True,
                                     capture_output=True, check=True)
    libcxx_version = None
    match = re.search(r"^\s*#\s*define\s+_LIBCPP_VERSION\s+(\d+)",
                      metadata_result.stdout, re.MULTILINE)
    if match:
        libcxx_version = int(match.group(1))

    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    sources = output / "sources"
    sources.mkdir(exist_ok=True)
    for name, source in PROBES.items():
        (sources / f"{name}.cpp").write_text(textwrap.dedent(source).lstrip(),
                                           encoding="utf-8")

    report = {
        "scope": "SDK-only target compilation; no compatibility headers, linking or runtime checks",
        "sdk_root": str(sdk),
        "sdk_metadata": read_metadata(sdk / "sdk-pkg.json"),
        "native_metadata": read_metadata(native / "oh-uni-package.json"),
        "compiler": version,
        "libcxx_version": libcxx_version,
        "libcxx_metadata_command": metadata_command,
        "results": [],
    }
    print(version.splitlines()[0])
    print(f"libc++ _LIBCPP_VERSION: {libcxx_version}")
    for abi in dict.fromkeys(args.abi or ["arm64-v8a"]):
        abi_output = output / abi
        abi_output.mkdir(exist_ok=True)
        print(f"\n{abi}: feature / default / experimental")
        for name in PROBES:
            statuses = []
            for mode in ("default", "experimental"):
                stem = abi_output / f"{name}-{mode}"
                command = [str(compiler), f"--target={TARGETS[abi]}",
                           f"--sysroot={sysroot}", "-std=c++20", "-fno-color-diagnostics"]
                if mode == "experimental":
                    command.append("-D_LIBCPP_ENABLE_EXPERIMENTAL")
                command.extend(["-c", str(sources / f"{name}.cpp"),
                                "-o", str(stem.with_suffix(".o"))])
                result = subprocess.run(command, text=True, capture_output=True)
                log = stem.with_suffix(".log")
                log.write_text(result.stdout + result.stderr, encoding="utf-8")
                report["results"].append({
                    "abi": abi,
                    "feature": name,
                    "mode": mode,
                    "passed": result.returncode == 0,
                    "exit_code": result.returncode,
                    "command": command,
                    "log": str(log),
                })
                statuses.append("PASS" if result.returncode == 0 else "FAIL")
            print(f"  {name}: {' / '.join(statuses)}")

    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n",
                           encoding="utf-8")
    print(f"\nReport: {report_path}")
    return 0 if all(result["passed"] for result in report["results"]) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"probe-cxx20: {error}", file=sys.stderr)
        sys.exit(2)
