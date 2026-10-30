"""Rendering half of summarize-bats-timing (Python 3 stdlib only).

Builds the Markdown summary and JSON record from `Stats`. Names reach the output
only through `md` and `clean`; the one workflow command is built from numbers.
"""

import os
import time

from bats_timing_core import AMBIGUOUS, TOP_FILES, TOP_TESTS, UNMAPPED, clean, md


def fmt_ms(ms):
    if ms < 1000:
        return "%dms" % ms
    return fmt_secs(ms / 1000.0, tenths=True)


def fmt_secs(secs, tenths=False):
    if secs < 60:
        return "%.1fs" % secs if tenths or secs < 10 else "%ds" % round(secs)
    secs = int(round(secs))
    return "%dm %02ds" % (secs // 60, secs % 60)


def read_epoch(path):
    try:
        with open(path, encoding="ascii") as fh:
            return float(fh.read(64).strip())
    except (OSError, ValueError):
        return None


def wall_seconds(args, stats):
    if args.wall_seconds is not None:
        return args.wall_seconds
    if args.start_epoch_file and args.log and args.log != "-":
        start = read_epoch(args.start_epoch_file)
        try:
            end = os.stat(args.log).st_mtime
        except OSError:
            end = None
        if stats.planned and stats.total < stats.planned:
            # Incomplete run (cancelled or timed out): the last write understates
            # how long the suite ran before it was killed; elapsed-until-now does not.
            end = time.time()
        if start is not None and end is not None and end >= start:
            return end - start
    if stats.last_stamp is not None:
        begin = stats.workers_stamp if stats.workers_stamp is not None else stats.first_stamp
        if begin is not None and stats.last_stamp >= begin:
            return stats.last_stamp - begin
    return None


def render(args, stats, wall, shard, notes):
    lines = ["## bats timing (shard: %s)" % shard, ""]
    lines.extend(notes)
    if notes:
        lines.append("")
    if stats.total == 0:
        lines.append("No bats test results were found in the log.")
        return lines
    lines.extend(["| Metric | Value |", "| --- | --- |"])
    lines.append(
        "| Tests reported | %d (%d passed, %d failed, %d skipped) |"
        % (stats.total, stats.passed, stats.failed, stats.skipped)
    )
    if stats.planned and stats.total < stats.planned:
        lines.append(
            "| Run incomplete | %d of %d planned tests reported (cancelled, timed out or crashed?) |"
            % (stats.total, stats.planned)
        )
    if stats.timed == 0:
        return lines + untimed_section() + failed_section(stats)
    lines.extend(metric_rows(args, stats, wall))
    return lines + slowest_tables(stats) + failed_section(stats)


def untimed_section():
    return [
        "| Timing | none |",
        "",
        "No per-test timings were present (`in Nms` or `# in N ms` suffixes). "
        "Run the suite with `ACQ_BATS_TIMING=1` to get slowest-test and slowest-file tables.",
    ]


def metric_rows(args, stats, wall):
    rows = ["| Summed test time | %s (setup and teardown included) |" % fmt_secs(stats.sum_ms / 1000.0, True)]
    if wall is not None and wall > 0:
        par = "%s wall" % fmt_secs(wall, True)
        par += ", %.1fx parallel" % (stats.sum_ms / 1000.0 / wall)
        if stats.workers:
            par += " (%d workers)" % stats.workers
        rows.append("| Suite wall time | %s |" % par)
    else:
        rows.append("| Suite wall time | unknown |")
    if args.timeout_minutes:
        rows.append(margin_row(args.timeout_minutes, wall))
    unmapped = sum(v[0] for k, v in stats.files.items() if k in (UNMAPPED, AMBIGUOUS))
    if unmapped:
        rows.append("| Tests not attributable to a file | %d |" % unmapped)
    return rows


def margin_row(timeout_minutes, wall):
    limit = timeout_minutes * 60.0
    if wall is not None and wall > 0 and limit > 0:
        return (
            "| Margin to %g min job timeout | %s left, suite used %.0f%% (suite only; checkout, setup and bash build also count) |"
            % (timeout_minutes, fmt_secs(max(limit - wall, 0)), 100.0 * wall / limit)
        )
    return "| Margin to %g min job timeout | unknown (no wall time) |" % timeout_minutes


def slowest_tables(stats):
    ranked = sorted(stats.slow, reverse=True)[:TOP_TESTS]
    lines = ["", "### Slowest %d tests" % len(ranked), "", "| # | Time | File | Test |", "| ---: | ---: | --- | --- |"]
    for i, (ms, _seq, name, file, _st) in enumerate(ranked, 1):
        lines.append("| %d | %s | %s | %s |" % (i, fmt_ms(ms), md(file), md(name)))
    files = sorted(stats.files.items(), key=lambda kv: (-kv[1][1], kv[0]))[:TOP_FILES]
    lines += ["", "### Slowest %d files (summed test time)" % len(files), "",
              "| # | File | Tests | Total | Slowest test |", "| ---: | --- | ---: | ---: | ---: |"]
    for i, (file, (n, ms, mx)) in enumerate(files, 1):
        lines.append("| %d | %s | %d | %s | %s |" % (i, md(file), n, fmt_ms(ms), fmt_ms(mx)))
    return lines


def failed_section(stats):
    if not stats.failed:
        return []
    out = ["", "### Failed tests", ""]
    for name, file in stats.failed_names:
        out.append("- %s: %s" % (md(file), md(name)))
    if stats.failed > len(stats.failed_names):
        out.append("- ... and %d more" % (stats.failed - len(stats.failed_names)))
    return out


def build_json(args, stats, wall, shard):
    limit = args.timeout_minutes * 60.0 if args.timeout_minutes else None
    return {
        "schema": 1,
        "shard": shard,
        "generated_at": int(time.time()),
        "tests": stats.total,
        "passed": stats.passed,
        "failed": stats.failed,
        "skipped": stats.skipped,
        "planned": stats.planned,
        "timed": stats.timed,
        "sum_ms": stats.sum_ms,
        "wall_seconds": None if wall is None else round(wall, 3),
        "workers": stats.workers,
        "timeout_minutes": args.timeout_minutes,
        "wall_fraction": None if (wall is None or not limit) else round(wall / limit, 4),
        "files": [
            {"file": clean(f), "tests": v[0], "ms": v[1], "max_ms": v[2]}
            for f, v in sorted(stats.files.items(), key=lambda kv: (-kv[1][1], kv[0]))
        ],
        "slowest_tests": [
            {"ms": ms, "file": clean(file), "name": clean(name), "status": st}
            for ms, _s, name, file, st in sorted(stats.slow, reverse=True)
        ],
    }
