#!/usr/bin/env python3
"""Summarize timestamped native diagnostics, selecting windows by log timestamp."""

import argparse
from datetime import datetime, time
import json
import math
from pathlib import Path
import re
import statistics


STAMP = re.compile(r'^\s*((?:\d{4}-)?\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2}(?:\.\d+)?)')
FIELD = re.compile(r'([A-Za-z_][A-Za-z_0-9]*)=([^\s]+)')
REQUIRED = {'submit_fps', 'upload_MiB_s', 'queue_max', 'coalesced'}


def parse_log(lines, year):
    windows, malformed = [], []
    for number, line in enumerate(lines, 1):
        if 'harmonyos perf:' not in line:
            continue
        try:
            stamp = STAMP.match(line)
            if not stamp:
                raise ValueError('missing timestamp')
            day, clock = stamp.groups()
            timestamp = datetime.fromisoformat(f'{day if len(day) == 10 else str(year) + "-" + day}T{clock}')
            fields = {}
            for name, value in FIELD.findall(line.split('harmonyos perf:', 1)[1]):
                values = tuple(float(part) for part in value.split('/'))
                if not all(math.isfinite(part) and part >= 0 for part in values):
                    raise ValueError(f'invalid {name}')
                if len(values) != (3 if name.endswith('_ms') else 1):
                    raise ValueError(f'invalid field shape: {name}')
                fields[name] = values if name.endswith('_ms') else values[0]
            if not REQUIRED.issubset(fields):
                raise ValueError('missing summary fields')
            windows.append((timestamp, fields))
        except (ValueError, TypeError) as error:
            malformed.append({'line': number, 'reason': str(error)})
    return windows, malformed


def boundary(value, day):
    if value is None:
        return None
    if re.fullmatch(r'\d{2}:\d{2}:\d{2}(?:\.\d+)?', value):
        return datetime.combine(day, time.fromisoformat(value))
    return datetime.fromisoformat(value)


def select_windows(windows, start, end, exclusions):
    return [(stamp, fields) for stamp, fields in windows
            if (start is None or stamp >= start) and (end is None or stamp <= end)
            and not any(first <= stamp <= last for first, last in exclusions)]


def stats(values):
    return {'mean': statistics.fmean(values), 'median': statistics.median(values),
            'min': min(values), 'max': max(values)}


def summarize(windows):
    result = {'windows': len(windows), 'first_timestamp': min(stamp for stamp, _ in windows).isoformat(),
              'last_timestamp': max(stamp for stamp, _ in windows).isoformat(), 'stages': {}}
    for name in sorted(REQUIRED):
        result[name] = stats([fields[name] for _, fields in windows])
    result['coalesced_total'] = sum(fields['coalesced'] for _, fields in windows)
    result['upload_bytes_per_second'] = stats([fields['upload_MiB_s'] * 1048576 for _, fields in windows])
    names = {name for _, fields in windows for name in fields if name.endswith('_ms')}
    for name in sorted(names):
        values = [fields[name] for _, fields in windows if name in fields]
        result['stages'][name.removesuffix('_ms')] = {
            'windows': len(values), 'window_mean_ms': stats([value[0] for value in values]),
            'window_p95_bucket_upper_ms': stats([value[1] for value in values]),
            'window_max_ms': stats([value[2] for value in values])}
    return result


def self_test():
    # Actual startup/settled field shapes; startup queue age must not contaminate
    # the settled two-window comparison selected by the user.
    sample = '''10-03 20:11:51.646 29709 29972 I OpenTTD_Engine: harmonyos perf: submit_fps=48.0 upload_MiB_s=56.70 queue_max=2 coalesced=3 queue_age_ms=6000.136/8192.000/6001.166 audio_ms=0.010/0.250/0.054
10-03 20:11:52.656 29709 29972 I OpenTTD_Engine: harmonyos perf: submit_fps=59.4 upload_MiB_s=17.99 queue_max=0 coalesced=4 audio_ms=0.049/0.250/0.090
10-03 20:11:53.662 29709 29972 I OpenTTD_Engine: harmonyos perf: submit_fps=60.6 upload_MiB_s=11.84 queue_max=0 coalesced=5 audio_ms=0.879/2.500/2.281
10-03 20:11:54.662 I OpenTTD_Engine: harmonyos perf: submit_fps=bad'''
    windows, malformed = parse_log(sample.splitlines(), 2026)
    assert len(windows) == 3 and len(malformed) == 1
    day = windows[0][0].date()
    selected = select_windows(windows, boundary('20:11:52', day), None, [])
    result = summarize(selected)
    assert result['windows'] == 2 and result['submit_fps']['mean'] == 60
    assert 'queue_age' not in result['stages'] and result['coalesced_total'] == 9
    assert result['stages']['audio']['window_p95_bucket_upper_ms']['median'] == 1.375
    assert result['stages']['audio']['window_p95_bucket_upper_ms']['max'] == 2.5
    assert math.isclose(result['upload_bytes_per_second']['mean'], 14.915 * 1048576)
    excluded = select_windows(windows, None, None,
                              [(boundary('20:11:51', day), boundary('20:11:52.999', day))])
    assert summarize(excluded)['submit_fps']['mean'] == 60.6
    assert len(select_windows(windows, boundary('2026-10-03T20:11:52', day),
                              boundary('20:11:53', day), [])) == 1
    print('PASS timestamp selection, exclusions, native-field parsing, window statistics')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', nargs='?', type=Path)
    parser.add_argument('--year', type=int, default=datetime.now().year,
                        help='Year for device MM-DD timestamps')
    parser.add_argument('--start', help='Inclusive summary timestamp: HH:MM:SS[.fff] or ISO date/time')
    parser.add_argument('--end', help='Inclusive summary timestamp: HH:MM:SS[.fff] or ISO date/time')
    parser.add_argument('--exclude', action='append', default=[], metavar='START..END',
                        help='Exclude summary timestamps in this inclusive range; repeat for multiple ranges')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.log is None:
        parser.error('a log file is required')
    windows, malformed = parse_log(args.log.read_text(errors='replace').splitlines(), args.year)
    if not windows:
        raise ValueError('no valid timestamped performance windows')
    day = windows[0][0].date()
    start, end = boundary(args.start, day), boundary(args.end, day)
    if start is not None and end is not None and end < start:
        raise ValueError('end must not precede start; use full dates for ranges across midnight')
    exclusions = []
    for value in args.exclude:
        first, last = (boundary(part, day) for part in value.split('..'))
        if last < first:
            raise ValueError('exclusion end must not precede start')
        exclusions.append((first, last))
    selected = select_windows(windows, start, end, exclusions)
    if not selected:
        raise ValueError('no performance windows match the selection')
    report = {'source': args.log.name, 'parsed_windows': len(windows), 'excluded_windows': len(windows) - len(selected),
              'malformed_windows': malformed,
              'selection': {'start': start.isoformat() if start else None, 'end': end.isoformat() if end else None,
                            'excluded_ranges': [[first.isoformat(), last.isoformat()] for first, last in exclusions]},
              'semantics': {'selection': 'Summary log timestamps, not individual samples; times use the device log clock.',
                            'averages': 'Unweighted window averages; per-window sample counts/durations are not logged.',
                            'p95': 'Median/min/max of window p95 bucket bounds, never a pooled sample p95.',
                            'fps': 'Successful EGL submissions, not confirmed presented frames.'},
              'measurements': summarize(selected)}
    output = json.dumps(report, indent=2, allow_nan=False) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output)
    else:
        print(output, end='')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, TypeError) as error:
        raise SystemExit(f'Performance summary failed: {error}')
