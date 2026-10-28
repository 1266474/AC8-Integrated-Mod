"""Summarize real PresentMon 1.x CSVs; never substitutes missing measurements.

The four 10 second phases are idle / steady drag / reverse drag / idle.
Times are relative to the first usable presentation unless --start-time is
supplied. This reports application presentation intervals, not input latency.
"""
from __future__ import annotations

import argparse
import csv
from collections import Counter
import json
import math
from pathlib import Path
import sys

PHASES = ("idle_before", "steady_drag", "reverse_drag", "idle_after")


def percentile(values: list[float], quantile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def summary(rows: list[tuple[float, float]]) -> dict:
    values = [ms for _, ms in rows]
    return {"frames": len(values), "p50_ms": percentile(values, .50),
            "p95_ms": percentile(values, .95), "p99_ms": percentile(values, .99),
            "maximum_ms": max(values) if values else None,
            "over_50ms": sum(ms > 50 for ms in values),
            "over_100ms": sum(ms > 100 for ms in values)}


def analyze(path: Path, *, start_time: float | None = None, process: str = "AceCombat8.exe", swapchain: str | None = None) -> dict:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        names = [name.strip().casefold() for name in (reader.fieldnames or [])]
        if len(names) != len(set(names)):
            raise ValueError("CSV has duplicate column names after case normalization")
        if "msbetweenpresents" not in names or "timeinseconds" not in names:
            raise ValueError("CSV must contain PresentMon v1 TimeInSeconds and MsBetweenPresents/msBetweenPresents columns")
        # Official PresentMon 2.x --v1_metrics uses a lowercase 'ms' prefix,
        # whereas older/FrameView variants used 'Ms'. Both describe the same
        # interval. Normalize every header consistently, including swapchains.
        records = [{key.strip().casefold(): value for key, value in record.items() if key is not None}
                   for record in reader]
    if not records:
        raise ValueError("CSV contains headers but no presentations")
    ignored_process = 0
    candidates = []
    for record in records:
        application = record.get("application", "")
        if application and Path(application.replace("\\", "/")).name.casefold() != process.casefold():
            ignored_process += 1
            continue
        candidates.append(record)
    if not candidates:
        raise ValueError(f"No presentations for {process}")
    # Auxiliary overlay/window swap chains must not be mixed into game cadence.
    chain_counts = Counter(record.get("swapchainaddress", "unspecified") for record in candidates)
    ranked_chains = chain_counts.most_common()
    chain = swapchain if swapchain is not None else ranked_chains[0][0]
    if chain not in chain_counts:
        raise ValueError(f"Requested swapchain is absent: {chain}")
    ambiguous_chain = swapchain is None and len(ranked_chains) > 1 and ranked_chains[1][1] >= ranked_chains[0][1] * .1
    selected = [record for record in candidates if record.get("swapchainaddress", "unspecified") == chain]
    parsed = []
    invalid = zero_intervals = 0
    for record in selected:
        try:
            time = float(record["timeinseconds"])
            ms = float(record["msbetweenpresents"])
            if not math.isfinite(time) or not math.isfinite(ms) or time < 0 or ms < 0:
                raise ValueError("Non-finite/negative presentation value")
            if ms == 0:
                zero_intervals += 1
                continue
            parsed.append((time, ms))
        except (ValueError, TypeError, KeyError):
            invalid += 1
    if not parsed:
        raise ValueError("No valid positive presentation intervals")
    if any(after[0] < before[0] for before, after in zip(parsed, parsed[1:])):
        raise ValueError("Presentation times moved backwards; do not concatenate runs")
    origin = parsed[0][0] if start_time is None else start_time
    if not math.isfinite(origin):
        raise ValueError("Start time must be finite")
    relative = [(time - origin, ms) for time, ms in parsed]
    window = [(time, ms) for time, ms in relative if 0 <= time < 40]
    if not window:
        raise ValueError("No presentations in the requested 40 second window")
    phases = {name: summary([(time, ms) for time, ms in window if index * 10 <= time < (index + 1) * 10])
              for index, name in enumerate(PHASES)}
    covered_until = max(time for time, _ in relative)
    complete = covered_until >= 39.5 and all(phase["frames"] for phase in phases.values())
    return {"source": str(path.resolve()), "measurement": "application present interval; not measured input latency",
            "time_origin_seconds": origin, "selected_swapchain": chain,
            "swapchain_selected_explicitly": swapchain is not None, "swapchain_ambiguous": ambiguous_chain,
            "swapchain_frame_counts": dict(chain_counts), "ignored_other_process": ignored_process,
            "ignored_other_swapchains": len(candidates) - len(selected),
            "invalid_rows": invalid, "zero_interval_rows": zero_intervals,
            "duration_seconds": covered_until, "complete_40s": complete,
            "usable_for_acceptance": complete and invalid == 0 and not ambiguous_chain,
            "total": summary(window), "drag_combined": summary([(t, m) for t, m in window if 10 <= t < 30]),
            "phases": phases}


def compare(baseline: dict, patched: dict) -> dict:
    a, b = baseline["drag_combined"], patched["drag_combined"]
    before, after = a["p99_ms"], b["p99_ms"]
    reduction = 100 * (before - after) / before if before and after is not None else None
    comparable = baseline["usable_for_acceptance"] and patched["usable_for_acceptance"]
    return {"comparable_complete_runs": comparable, "drag_p99_reduction_percent": reduction,
            "target_p99_reduction_percent": 30,
            "p99_target_met": comparable and reduction is not None and reduction >= 30,
            "over_50ms_before_after": [a["over_50ms"], b["over_50ms"]],
            "over_100ms_before_after": [a["over_100ms"], b["over_100ms"]],
            "note": "Visual stutter and matched game scene must be assessed separately; three repeated runs are required."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    parser.add_argument("--compare", type=Path, help="Patched CSV to compare with the first/baseline CSV")
    parser.add_argument("--start-time", type=float)
    parser.add_argument("--patched-start-time", type=float)
    parser.add_argument("--swapchain", help="Explicit main game swapchain address if automatic selection is ambiguous")
    parser.add_argument("--patched-swapchain")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        baseline = analyze(args.csv, start_time=args.start_time, swapchain=args.swapchain)
        result = baseline
        if args.compare:
            patched = analyze(args.compare, start_time=args.patched_start_time, swapchain=args.patched_swapchain)
            result = {"baseline": baseline, "patched": patched, "comparison": compare(baseline, patched)}
        content = json.dumps(result, ensure_ascii=False, indent=2)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(content + "\n", encoding="utf-8")
        print(content)
        return 0
    except Exception as error:
        print(f"UNUSABLE: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
