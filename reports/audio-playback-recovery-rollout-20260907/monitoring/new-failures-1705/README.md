# 17:05 cumulative-window failure delta

The cumulative count is **12 = 9 known + 3 newly observed**. All three new client events and all three Direct 400s occurred **before** the proxy, Global API and Direct gateway releases. They are not evidence of a regression in the newly deployed versions.

The client query read all 90 selected end events in the original 05:01:25–17:05:27.598373 UTC window and reproduced the acceptance snapshot's 12 technical failures. The three new events belong to one anonymous Android installation running **1.0.45 / build 52**, using Global routing. Their same-session read starts identify URL/Web input. No text, URLs, raw identities or request bodies were queried or exported.

| Client event key | Occurred UTC | Same-session input / language | Playback seconds | Failure |
|---|---|---|---:|---|
| e08918341c4265a32e2a | 16:04:04.923 | URL/Web / en | 44 | tts_failed / generation_failed / tts |
| 798ead151458637a016f | 16:04:17.983 | Same content, resumed / es | 0 | tts_failed / generation_failed / tts |
| 855d7b43d4f616193757 | 16:13:12.965 | Another URL/Web content session / es | 48 | tts_failed / generation_failed / tts |

Each reading session has a preceding first-audio event (reported latency 1963 / 1327 / 1342 ms respectively). The second session reports failure about 551 ms after first audio with 0 playback seconds. These are client events, not proof of successful decoding or complete playback. Later starts or completed sessions sharing a content session are separate sessions and do not erase these failures.

The Direct journal query is complete: 43,627 rows / 4,354 logical blocks, with no truncation or parser gaps. Its three 400 records are:

| Direct anonymous key | Completion/log UTC | Elapsed | Request bytes | Client metadata |
|---|---|---:|---:|---|
| 7fe6315b3454e3737bc7 | 16:04:04.896206 | 14 ms | 583 | Android 1.0.45 |
| e4331852bd595754975e | 16:04:17.957222 | 13 ms | 583 | Android 1.0.45 |
| 8a0585d2909dc89be5b7 | 16:13:12.950192 | 357 ms | 165 | Android 1.0.45 |

These respectively precede the client occurrence timestamps by 26.794 / 25.778 / 14.808 ms. The timing and platform/version agreement make them strong association candidates. They are **not exact request joins**: the selected client request/trace properties are absent, and occurrence time is client supplied. Server receipt timestamps (16:04:07.099 / 16:04:20.322 / 16:13:15.168) independently establish that all three client failures were received before every deployment.

The old Direct source does not log the 400 response body, error code, generation layer, abort stage or disconnection state. Those fields remain unavailable rather than false. Positive `requestBytes` indicates that the inbound body was fully read; invalid JSON/input validation and a forwarded upstream 400 remain possible. The 13–357 ms durations do not establish where the 400 originated, nor do they make these timeout events.

Deployment boundaries used: proxy verified 16:36:52.292087; Global identity readback 16:45:55.382733; Direct first new traffic 16:51:50.888941, verified 16:52:02.458777 UTC. The four historical Direct 504s and four historical Global 504s remain unchanged.

Artifacts: `client-delta.json` retains the allowed session metadata and completeness checks; `client-summary.json` is the compact client table; `direct400.json` contains the sanitized journal evidence and current Direct identity; `combined-summary.json` records candidate links and their limits. Active notification state and production configuration were not modified.
