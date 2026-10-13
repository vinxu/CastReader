#!/usr/bin/env python3
"""Build a compact in-conversation blind A/B audio listener."""

from __future__ import annotations

import argparse
import base64
import html
import json
import subprocess
from pathlib import Path


CATEGORY_LABELS = {
    "indoor-kitchen": "室内 · 厨房",
    "indoor-living-room": "室内 · 客厅",
    "indoor-washing-machine": "室内 · 洗衣机",
    "indoor-meeting-room": "室内 · 会议室",
    "indoor-office": "室内 · 办公室",
    "public-cafeteria": "公共空间 · 食堂",
    "outdoor-field": "室外 · 田野",
    "outdoor-park": "室外 · 公园",
    "public-station": "公共空间 · 车站",
    "outdoor-public-square": "室外 · 广场",
    "outdoor-traffic": "室外 · 交通路口",
    "transport-metro": "交通工具 · 地铁",
}


def opus_data_url(path: Path, bitrate: str) -> str:
    completed = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(path),
            "-ac",
            "1",
            "-ar",
            "24000",
            "-c:a",
            "libopus",
            "-application",
            "voip",
            "-b:a",
            bitrate,
            "-vbr",
            "off",
            "-f",
            "ogg",
            "pipe:1",
        ],
        check=True,
        capture_output=True,
    )
    return "data:audio/ogg;base64," + base64.b64encode(completed.stdout).decode("ascii")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("clone_results", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--bitrate", default="20k")
    args = parser.parse_args()

    report = json.loads(args.clone_results.read_text(encoding="utf-8"))
    root = args.clone_results.parent
    cases: list[str] = []
    for index, record in enumerate(report["records"], start=1):
        sample_id = str(record["sample_id"])
        category = str(record["category"])
        label = CATEGORY_LABELS.get(category, category)
        blind_dir = root / "blind" / sample_id
        source_a = opus_data_url(blind_dir / "A.wav", args.bitrate)
        source_b = opus_data_url(blind_dir / "B.wav", args.bitrate)
        cases.append(
            f"""
            <section class="dab-case" data-case="{html.escape(sample_id)}">
              <div class="dab-case-heading">
                <h3>{index:02d} · {html.escape(label)}</h3>
                <span class="viz-badge">目标 SNR {float(record['target_snr_db']):.0f} dB</span>
              </div>
              <div class="dab-players">
                <label><span>A</span><audio controls preload="none" src="{source_a}"></audio></label>
                <label><span>B</span><audio controls preload="none" src="{source_b}"></audio></label>
              </div>
              <fieldset class="dab-choice">
                <legend class="sr-only">第 {index} 组主观选择</legend>
                <label class="form-check"><input class="form-check-input" type="radio" name="choice-{index}" value="A 更好"><span class="form-check-label">A 更好</span></label>
                <label class="form-check"><input class="form-check-input" type="radio" name="choice-{index}" value="B 更好"><span class="form-check-label">B 更好</span></label>
                <label class="form-check"><input class="form-check-input" type="radio" name="choice-{index}" value="差不多"><span class="form-check-label">差不多</span></label>
                <label class="form-check"><input class="form-check-input" type="radio" name="choice-{index}" value="都不好"><span class="form-check-label">都不好</span></label>
              </fieldset>
            </section>
            """
        )

    fragment = f"""
<div id="castreader-denoise-listener">
  <style>
    #castreader-denoise-listener {{ color: var(--foreground); width: 100%; }}
    #castreader-denoise-listener .dab-intro {{ margin-bottom: 16px; }}
    #castreader-denoise-listener .dab-intro p {{ color: var(--muted-foreground); margin: 4px 0 0; }}
    #castreader-denoise-listener .dab-case {{ padding: 16px 0; border-bottom: 1px solid var(--border); }}
    #castreader-denoise-listener .dab-case-heading {{ display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; margin-bottom: 10px; }}
    #castreader-denoise-listener .dab-case-heading h3 {{ margin: 0; font-weight: 500; }}
    #castreader-denoise-listener .dab-players {{ display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }}
    #castreader-denoise-listener .dab-players label {{ display: grid; grid-template-columns: 20px minmax(0, 1fr); align-items: center; gap: 8px; font-weight: 500; }}
    #castreader-denoise-listener audio {{ width: 100%; min-width: 0; }}
    #castreader-denoise-listener .dab-choice {{ display: flex; gap: 10px 18px; flex-wrap: wrap; border: 0; padding: 10px 0 0; margin: 0; }}
    #castreader-denoise-listener .dab-actions {{ display: flex; align-items: center; gap: 12px; flex-wrap: wrap; padding-top: 18px; }}
    #castreader-denoise-listener .dab-status {{ color: var(--muted-foreground); }}
    @media (max-width: 560px) {{
      #castreader-denoise-listener .dab-players {{ grid-template-columns: 1fr; }}
    }}
  </style>
  <div class="dab-intro">
    <h2>声音克隆降噪盲听 · 12 组</h2>
    <p>A/B 已随机；两边使用同一输入、同一试听文案和同一随机种子。每次只播放一个音频。</p>
  </div>
  {''.join(cases)}
  <div class="dab-actions">
    <button type="button" class="btn btn-primary" id="dab-submit">提交已选结果</button>
    <span class="dab-status" id="dab-status" aria-live="polite"></span>
  </div>
  <script>
    (() => {{
      const root = document.getElementById('castreader-denoise-listener');
      const status = root.querySelector('#dab-status');
      root.querySelectorAll('audio').forEach((player) => {{
        player.addEventListener('play', () => {{
          root.querySelectorAll('audio').forEach((other) => {{
            if (other !== player) other.pause();
          }});
        }});
      }});
      root.querySelector('#dab-submit').addEventListener('click', async () => {{
        const choices = [];
        root.querySelectorAll('.dab-case').forEach((item, index) => {{
          const selected = item.querySelector('input[type="radio"]:checked');
          if (selected) choices.push(`${{String(index + 1).padStart(2, '0')}} ${{item.dataset.case}}：${{selected.value}}`);
        }});
        if (!choices.length) {{
          status.textContent = '请至少选择一组。';
          return;
        }}
        status.textContent = `已选择 ${{choices.length}} / {len(report['records'])} 组`;
        if (window.openai?.sendFollowUpMessage) {{
          await window.openai.sendFollowUpMessage({{
            title: '提交降噪盲听结果',
            prompt: `这是我对声音克隆降噪 A/B 的盲听选择：\\n${{choices.join('\\n')}}\\n请读取本任务的 answer-key.json，汇总新管线胜率并判断下一步。`
          }});
        }}
      }});
    }})();
  </script>
</div>
"""
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(fragment, encoding="utf-8")
    size = args.output.stat().st_size
    if size >= 1_000_000:
        raise RuntimeError(f"visualization exceeds 1 MB: {size} bytes")
    print(f"wrote {args.output} ({size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
