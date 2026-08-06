#!/usr/bin/env python3
"""ASO 排名快照：iTunes Search API 逐市场逐词查 CastReader 排名，追加到时间序列。

用法：python3 scripts/aso_rank_snapshot.py
输出：docs/aso/rank-history.jsonl（追加一批 {date, market, term, rank}）+ 终端对比表。
排名 = 该词搜索结果前 100 中 trackId 的位置；>100 记为 None（打印 ">100"）。
词表改动直接改本文件 TERMS（与 docs/aso/keyword-corpus.md 保持同步）。
"""
import json
import time
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path

APP_ID = 6757636395
OUT = Path(__file__).resolve().parent.parent / "docs" / "aso" / "rank-history.jsonl"

# 市场 → 追踪词。原则：每市场 6–10 个，覆盖「大词 / 场景长尾 / 人群词 / 自有词」四类。
TERMS: dict[str, list[str]] = {
    "us": [
        "text to speech", "read aloud", "listen to pdf", "pdf to audio",
        "pdf reader aloud", "listen to articles", "kindle read aloud",
        "dyslexia reading app", "ai explain reader", "text reader",
        # 点点数据验证在榜的词（2026-08-04 起跟踪；注意 iTunes API 与真实商店排名有偏差，本脚本只看趋势）
        "read aloud free", "ebook reader", "reading", "aloud reader", "eleven reader",
    ],
    "gb": ["text to speech", "read aloud", "listen to pdf", "pdf reader aloud", "read aloud free"],
    "jp": ["読み上げ", "テキスト読み上げ", "音声読み上げ", "pdf 読み上げ", "リーダー 音声"],
    "de": ["vorlesen", "text zu sprache", "pdf vorlesen", "vorlese app", "hörbuch pdf"],
    "fr": ["synthèse vocale", "lecture à voix haute", "lire pdf voix", "écouter pdf"],
    "es": ["texto a voz", "leer en voz alta", "escuchar pdf", "lector de pdf voz"],
    "it": ["sintesi vocale", "lettura vocale", "leggere pdf voce", "ascoltare pdf"],
    "br": ["texto em voz", "ler em voz alta", "ouvir pdf", "leitor de voz"],
}


def rank_for(term: str, market: str) -> int | None:
    # quote_via=quote：itunes 对「重音字符 + 空格转 +」的组合会 404，必须用 %20
    q = urllib.parse.urlencode(
        {"term": term, "country": market, "entity": "software", "limit": 100},
        quote_via=urllib.parse.quote,
    )
    req = urllib.request.Request(
        f"https://itunes.apple.com/search?{q}", headers={"User-Agent": "curl/8"}
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        results = json.load(resp).get("results", [])
    for i, r in enumerate(results, 1):
        if r.get("trackId") == APP_ID:
            return i
    return None


def load_previous() -> dict[tuple[str, str], int | None]:
    prev: dict[tuple[str, str], dict] = {}
    if OUT.exists():
        for line in OUT.read_text().splitlines():
            row = json.loads(line)
            prev[(row["market"], row["term"])] = row  # 后写覆盖先写 → 留下最近一次
    return {k: v["rank"] for k, v in prev.items()}


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    prev = load_previous()
    today = date.today().isoformat()
    rows = []
    print(f"=== ASO 排名快照 {today}（对比上次） ===")
    for market, terms in TERMS.items():
        for term in terms:
            try:
                rank = rank_for(term, market)
            except Exception as exc:  # 限流/网络：记录后继续
                print(f"  {market} {term!r} 查询失败: {exc}")
                continue
            rows.append({"date": today, "market": market, "term": term, "rank": rank})
            old = prev.get((market, term), "∅")
            cur = rank if rank is not None else ">100"
            old_s = old if old is not None else ">100"
            delta = ""
            if isinstance(old, int) and isinstance(rank, int) and old != rank:
                delta = f"  ({'↑' if rank < old else '↓'}{abs(old - rank)})"
            elif old == "∅":
                delta = "  (新)"
            print(f"  {market:3} {term:28} {old_s!s:>5} → {cur!s:>5}{delta}")
            time.sleep(0.8)  # itunes search API 限流保护
    with OUT.open("a") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"已追加 {len(rows)} 条 → {OUT.relative_to(Path.cwd()) if OUT.is_relative_to(Path.cwd()) else OUT}")


if __name__ == "__main__":
    main()
