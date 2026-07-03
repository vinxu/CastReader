#!/usr/bin/env python3
"""Analyze CastReader Kindle probe logs for playback/visual drift.

Usage:
  scripts/analyze_kindle_probe_log.py /path/to/kindle-background-probe.log
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path


KEY = r"([0-9a-f]{8,16})"


@dataclass
class Issue:
    severity: str
    time: str
    code: str
    detail: str


def short(key: str) -> str:
    return key[:8] if key else ""


def analyze(lines: list[str]) -> tuple[dict[str, int], list[Issue]]:
    stats = {
        "segments": 0,
        "page_switches": 0,
        "highlight_mismatches": 0,
        "visual_matches": 0,
        "visual_no_matches": 0,
        "soft_reverted": 0,
        "soft_blocked": 0,
        "paragraph_scrolls": 0,
        "paragraph_scroll_large": 0,
        "paragraph_scroll_mismatch": 0,
        "native_page_updates": 0,
        "native_page_mismatch": 0,
        "native_page_missing": 0,
        "explain_starts": 0,
        "explain_pages": 0,
        "explain_plans": 0,
        "explain_blocks_prepared": 0,
        "explain_blocks_enqueued": 0,
        "explain_raw_marks": 0,
        "explain_placed_marks": 0,
        "explain_zero_mark_blocks": 0,
        "explain_summaries": 0,
        "explain_errors": 0,
        "explain_mark_errors": 0,
        "explain_prefetch_empty": 0,
        "explain_prefetch_load_more": 0,
        "explain_prefetch_load_more_hits": 0,
        "explain_advances": 0,
        "explain_replayed_pages": 0,
        "source_read_empty": 0,
        "source_explain_empty": 0,
        "source_anchor_missing": 0,
        "source_app_inactive": 0,
        "pipeline_issues": 0,
    }
    issues: list[Issue] = []
    playback_key = ""
    pending_native_page_key = ""
    last_match_by_target: dict[str, str] = {}
    low_score_streak: dict[str, int] = {}
    explain_expected_blocks = 0
    explain_prepared_blocks_since_plan = 0
    explain_seen_pages: set[str] = set()

    for raw in lines:
        line = raw.rstrip("\n")
        time = line[:8] if re.match(r"\d\d:\d\d:\d\d", line) else "??:??:??"

        if "KINDLE continuous EXPLAIN start" in line:
            stats["explain_starts"] += 1
            explain_expected_blocks = 0
            explain_prepared_blocks_since_plan = 0

        if "KINDLE explain error" in line:
            stats["explain_errors"] += 1
            issues.append(Issue("P0", time, "EXPLAIN_ERROR", line.split("KINDLE explain error", 1)[-1].strip()))

        if "KINDLE marks error" in line:
            stats["explain_mark_errors"] += 1
            issues.append(Issue("P1", time, "EXPLAIN_MARK_RENDER_ERROR", line.split("KINDLE marks error", 1)[-1].strip()))

        if re.search(r"KINDLE explain prefetch after=.* candidates= held=", line):
            stats["explain_prefetch_empty"] += 1

        if "KINDLE explain prefetch load-more after=" in line:
            stats["explain_prefetch_load_more"] += 1

        if m := re.search(r"KINDLE explain prefetch load-more result .* candidates=([^ ]*)", line):
            if m.group(1):
                stats["explain_prefetch_load_more_hits"] += 1

        if "KINDLE explain advance from=" in line:
            stats["explain_advances"] += 1

        if m := re.search(r"KINDLE source (read|explain) .* candidates=([^ ]*) .* reason=([^ ]+)", line):
            mode, candidates, reason = m.groups()
            if not candidates:
                stats[f"source_{mode}_empty"] += 1
            if "anchor-not-held" in reason:
                stats["source_anchor_missing"] += 1
                issues.append(Issue("P1", time, "SOURCE_ANCHOR_NOT_HELD", line.split("KINDLE source", 1)[-1].strip()))
            if "app-not-active" in reason:
                stats["source_app_inactive"] += 1

        if m := re.search(r"KINDLE pipeline issue kind=([^ ]+) title=(.*)", line):
            stats["pipeline_issues"] += 1
            kind, title = m.groups()
            severity = "P0" if kind in {"pageFailed", "sourceNotReady"} else "P1"
            issues.append(Issue(severity, time, "PIPELINE_ISSUE", f"{kind}: {title}"))

        if m := re.search(r"KINDLE explain page reason=([^ ]*) key=" + KEY, line):
            stats["explain_pages"] += 1
            reason, key = m.groups()
            if reason != "initial" and key in explain_seen_pages:
                stats["explain_replayed_pages"] += 1
                issues.append(Issue("P0", time, "EXPLAIN_REPLAYED_PAGE", f"{reason} selected already explained key={short(key)}"))
            explain_seen_pages.add(key)

        if m := re.search(r"KINDLE explain plan .* total=(\d+)", line):
            stats["explain_plans"] += 1
            explain_expected_blocks = int(m.group(1))
            explain_prepared_blocks_since_plan = 0

        if m := re.search(r"KINDLE explain prepare block=(\d+) rawMarks=(\d+) placed=(\d+) timeline=(\d+)", line):
            block, raw_marks, placed_marks, timeline = (int(v) for v in m.groups())
            stats["explain_blocks_prepared"] += 1
            stats["explain_raw_marks"] += raw_marks
            stats["explain_placed_marks"] += placed_marks
            explain_prepared_blocks_since_plan += 1
            if raw_marks > 0 and placed_marks == 0:
                stats["explain_zero_mark_blocks"] += 1
                issues.append(Issue("P1", time, "EXPLAIN_MARKS_NOT_PLACED", f"block={block} rawMarks={raw_marks} timeline={timeline}"))
            elif raw_marks >= 4 and placed_marks / raw_marks < 0.35:
                issues.append(
                    Issue(
                        "P1",
                        time,
                        "EXPLAIN_LOW_MARK_PLACEMENT",
                        f"block={block} rawMarks={raw_marks} placed={placed_marks} rate={placed_marks / raw_marks:.2f}",
                    )
                )

        if re.search(r"KINDLE explain block=\d+ .*segs=\d+ marks=\d+ dur=", line):
            stats["explain_blocks_enqueued"] += 1

        if m := re.search(r"KINDLE explain summary .*len=(\d+)", line):
            stats["explain_summaries"] += 1
            if int(m.group(1)) <= 0:
                issues.append(Issue("P1", time, "EXPLAIN_EMPTY_PAGE_SUMMARY", "cross-page continuity summary is empty"))

        if m := re.search(r"KINDLE continuous page reason=.* key=" + KEY, line):
            playback_key = m.group(1)

        if m := re.search(r"KINDLE playback page switch key=" + KEY, line):
            playback_key = m.group(1)
            pending_native_page_key = playback_key
            stats["page_switches"] += 1

        if m := re.search(r"KINDLE native page key=" + KEY, line):
            native_key = m.group(1)
            stats["native_page_updates"] += 1
            if playback_key and short(native_key) != short(playback_key):
                stats["native_page_mismatch"] += 1
                issues.append(
                    Issue(
                        "P0",
                        time,
                        "NATIVE_PAGE_NOT_PLAYING_PAGE",
                        f"playing={short(playback_key)} native={short(native_key)}",
                    )
                )
            if pending_native_page_key:
                if short(native_key) == short(pending_native_page_key):
                    pending_native_page_key = ""
                else:
                    stats["native_page_mismatch"] += 1
                    issues.append(
                        Issue(
                            "P0",
                            time,
                            "NATIVE_PAGE_SWITCH_MISMATCH",
                            f"expected={short(pending_native_page_key)} native={short(native_key)}",
                        )
                    )

        if re.search(r"KINDLE continuous segment key=", line):
            stats["segments"] += 1

        if m := re.search(
            r"KINDLE highlight page-mismatch:([0-9a-f]+).* target=([0-9a-f]+) visual=([0-9a-f]+)",
            line,
        ):
            visible, target, visual = m.groups()
            stats["highlight_mismatches"] += 1
            if playback_key and short(target) == short(playback_key):
                issues.append(
                    Issue(
                        "P0",
                        time,
                        "PLAYING_PAGE_VISUAL_DRIFT",
                        f"playing={short(playback_key)} target={short(target)} visible={short(visible)} visualAnchor={short(visual)}",
                    )
                )
            else:
                issues.append(
                    Issue(
                        "P1",
                        time,
                        "TARGET_VISIBLE_MISMATCH",
                        f"currentPlaying={short(playback_key)} target={short(target)} visible={short(visible)} visualAnchor={short(visual)}",
                    )
                )

        if m := re.search(
            r"KINDLE visual content attempt=(\d+) target=([0-9a-f]+) visible=([0-9a-f]+) score=([0-9.]+)",
            line,
        ):
            _, target, _visible, score_raw = m.groups()
            score = float(score_raw)
            if score < 0.18:
                low_score_streak[target] = low_score_streak.get(target, 0) + 1
            else:
                low_score_streak[target] = 0

        if m := re.search(
            r"KINDLE visual content match target=([0-9a-f]+) visual=([0-9a-f]+) score=([0-9.]+)",
            line,
        ):
            target, visual, score_raw = m.groups()
            stats["visual_matches"] += 1
            last_match_by_target[target] = visual
            low_score_streak[target] = 0
            score = float(score_raw)
            if score < 0.34:
                issues.append(
                    Issue("P1", time, "WEAK_VISUAL_MATCH", f"target={short(target)} visual={short(visual)} score={score:.2f}")
                )

        if m := re.search(
            r"KINDLE visual content no-match target=([0-9a-f]+) best=([0-9a-f]+) score=([0-9.]+)",
            line,
        ):
            target, best, score_raw = m.groups()
            stats["visual_no_matches"] += 1
            issues.append(
                Issue(
                    "P0",
                    time,
                    "VISUAL_SEEK_NO_MATCH",
                    f"target={short(target)} best={short(best)} score={float(score_raw):.2f} lowScoreAttempts={low_score_streak.get(target, 0)}",
                )
            )

        if "JS softScroll" in line or "JS softScrollBlocked" in line:
            rev = "rev:true" in line
            before = re.search(r"before:([0-9a-f]{0,8})", line)
            after = re.search(r"after:([0-9a-f]{0,8})", line)
            expected = re.search(r"exp:([0-9a-f]{0,8})", line)
            reason = re.search(r"reason:([^ ]*)", line)
            if rev:
                stats["soft_reverted"] += 1
                issues.append(
                    Issue(
                        "P1",
                        time,
                        "SOFT_SCROLL_REVERTED",
                        f"expected={expected.group(1) if expected else ''} before={before.group(1) if before else ''} after={after.group(1) if after else ''}",
                    )
                )
            if "softScrollBlocked" in line:
                stats["soft_blocked"] += 1
                issues.append(
                    Issue(
                        "P1",
                        time,
                        "SOFT_SCROLL_BLOCKED",
                        f"expected={expected.group(1) if expected else ''} before={before.group(1) if before else ''} after={after.group(1) if after else ''} reason={reason.group(1) if reason else ''}",
                    )
                )

        if m := re.search(
            r"KINDLE paragraph scroll key=([0-9a-f]+) visual=([0-9a-f]+) p=(\d+) needed=(true|false) delta=([-0-9.]+) before=([0-9a-f]*) after=([0-9a-f]*) reverted=(true|false) reason=([^ ]*)",
            line,
        ):
            key, visual, para, needed, delta_raw, before, after, reverted_raw, reason = m.groups()
            delta = abs(float(delta_raw))
            stats["paragraph_scrolls"] += 1
            if delta > 180:
                stats["paragraph_scroll_large"] += 1
                issues.append(
                    Issue("P1", time, "PARAGRAPH_SCROLL_TOO_LARGE", f"key={short(key)} p={para} delta={delta:.0f}")
                )
            if reason == "before-mismatch" or (before and visual and short(before) != short(visual)):
                stats["paragraph_scroll_mismatch"] += 1
                issues.append(
                    Issue(
                        "P0",
                        time,
                        "PARAGRAPH_SCROLL_WRONG_VISIBLE_PAGE",
                        f"key={short(key)} visual={short(visual)} before={short(before)} after={short(after)} p={para}",
                    )
                )
            if reverted_raw == "true":
                issues.append(
                    Issue("P1", time, "PARAGRAPH_SCROLL_REVERTED", f"key={short(key)} p={para} before={short(before)} after={short(after)}")
                )

    if pending_native_page_key:
        stats["native_page_missing"] += 1
        issues.append(
            Issue(
                "P0",
                "EOF",
                "NATIVE_PAGE_SWITCH_MISSING",
                f"expected={short(pending_native_page_key)}",
            )
        )

    if explain_expected_blocks > 0 and explain_prepared_blocks_since_plan > explain_expected_blocks:
        issues.append(
            Issue(
                "P1",
                "EOF",
                "EXPLAIN_BLOCK_COUNT_EXCEEDED",
                f"expected={explain_expected_blocks} prepared={explain_prepared_blocks_since_plan}",
            )
        )

    return stats, issues


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"Log not found: {path}", file=sys.stderr)
        return 2

    lines = path.read_text(errors="replace").splitlines()
    stats, issues = analyze(lines)

    print("Kindle Probe Analysis")
    print(f"lines={len(lines)}")
    for key, value in stats.items():
        print(f"{key}={value}")

    if not issues:
        print("result=PASS")
        return 0

    print("result=FAIL")
    for issue in issues[:40]:
        print(f"{issue.severity} {issue.time} {issue.code} {issue.detail}")
    if len(issues) > 40:
        print(f"... {len(issues) - 40} more issues")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
