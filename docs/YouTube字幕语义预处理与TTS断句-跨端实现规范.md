# YouTube 字幕语义预处理与 TTS 断句：跨端实现规范

> 更新日期：2026-08-13<br>
> 语义合同：`YouTubeCaptionSemanticSchema = 3`<br>
> 适用端：iOS / Android<br>
> 状态：iOS / Android P0 已落地，按本文与共享 golden fixture 持续对齐

本文定义 YouTube 字幕从「带时间的 cue」到「可见字幕 + 可朗读文本 + TTS utterance」的确定性合同。目标不是简单删正则，而是同时解决四类会直接破坏听感的问题：

1. `[Music]`、`[掌声]`、`(whispering)` 等可访问性标注被 TTS 当作台词。
2. `>> ALICE:`、WebVTT `<v Alice>` 等角色证据丢失，对话被合成一段。
3. YouTube rolling caption 重复前一个窗口的文字，TTS 重复朗读。
4. 仅按字幕行或字符数切段，使一句话在中间停顿、重起音。

P0 是纯本地、可重放、无模型推理的语义预处理。同一组 cue 在两端必须生成完全相同的 `(id, text, speechText, startMs, speaker)`。

---

## 1. P0 范围与非目标

P0 产出高置信的角色元数据，用它切断 utterance、保留界面语义，并让 TTS 避开角色名与环境音标签。

P0 **不做**以下事情：

- 不根据 `speaker` 自动切换多音色。当前仍用用户选定的单一音色；`speaker` 是分段、展示和后续多音色的元数据。
- 不从声纹、音频或画面猜角色；只使用字幕格式与文本内的高置信证据。
- 不把「男声」、「女声」等标签映射到特定 TTS voice，也不根据名字推测性别。
- 不删除未知标注。宁可少删，不可把正文误删或把「章节:」误当角色。
- 不改写、翻译、补标点或总结字幕。

---

## 2. 数据模型：可见原文与可朗读文本必须分开

### 2.1 Cue

```text
YouTubeTranscriptCue
  text: String               // 提取到的可见 cue 文本
  startMs: Int64             // 开始时间
  durationMs: Int64 = 0      // 持续时间；未知时为 0
  speaker: String?           // 仅存格式自带的结构化角色，如 WebVTT <v>
```

`cue.text` 是指纹和重新派生的源，不要在提取层就删掉标签。WebVTT `<v Alice>Hello</v>` 必须产出 `text = "Hello"` 与 `speaker = "Alice"`，不可只展平成 `Alice: Hello`。

同一个 WebVTT cue 内若存在多个 `<v>`，提取层先建立有序 voice-turn 列表。只有 voice 节点覆盖了该 cue 的全部可见非空白文本，且每个 turn 的 `speaker/text` 都非空时，才允许拆成多个 cue；相邻同名 voice 节点先合并。若有前缀、尾随或夹在中间的无归属正文，则保持一条 `speaker = null` 的普通 cue，全文 fail-open，禁止猜角色或丢字。拆分后的 `startMs/durationMs` 按各 turn 的 UTF-16 文本长度权重投影，边界取整后必须单调，首尾覆盖原 cue 的完整时间区间，不伪造词级时间戳。

### 2.2 Paragraph / utterance

```text
YouTubeTranscriptParagraph
  id: Int                    // 从 0 连续递增，包括纯环境音段
  text: String               // 用户看到的字幕，保留角色/环境音/语气标注
  speechText: String?        // 专用于 TTS 的派生文本
  startMs: Int64
  speaker: String?           // 仅高置信；未知为 null

resolvedSpeechText = speechText ?? text
```

`nil/null` 与空字符串的语义不同：

- `speechText == null`：旧缓存没有该字段，安全回退到 `text`。
- `speechText == ""`：已经分类为纯非语音段，必须显示但不可朗读。

`text` 是「显示保真」而非字节级原样：单个 cue 会保留标签，但段落派生时统一折叠换行/连续空白。真正的原始来源仍是 `cues[]`。

---

## 3. 固定处理顺序

顺序是合同的一部分，不能自由交换。典型反例是 `[Music] ALICE: Hello`：必须先去掉领头环境音标签，才能识别后面的 `ALICE:`。

1. **稳定排序**：按 `startMs` 升序；时间相同时保留输入顺序。
2. **显示归一化**：换行和连续空白折叠为单空格；空 cue 丢弃。
3. **开场 metadata 分类**：只用完整 field/value grammar 识别制作署名；正文一律 fail-open。
4. **全局角色证据预扫描**：先收集 `Name:` 的语法候选，再按独立发言 episode 计票并构建 blocked-alias 图；rolling transport update 不得重复投票。
5. **分解单 cue 内多轮对话**：仅在有效 `>>` / `＞＞` 转轮证据下分开。
6. **第一遍语义标签剥离**：先处理领头环境音、语气、不可辨识和角色标签。
7. **角色前缀识别**：结合结构化 `speaker`、`>>`、全局重复证据与内置角色词表，保守地剥离 `Name:`。
8. **第二遍语义标签剥离**：处理角色前缀后才暴露出来的连续标签。
9. **音乐符号剥离**：仅从 `speechText` 去掉 `♪♫♩♬🎵🎶`，歌词本身保留。
10. **可朗读性判定**：至少含字母、数字、中日韩文或天城文字才进入 TTS；否则是空 `speechText`。
11. **rolling caption 去重**：只从 `speechText` 删前窗口重复部分，不改可见 `text`。
12. **cue 内自然句切分**：先按终止标点，再按硬上限/持续时间切开过大 cue。
13. **跨 cue utterance 分组**：按语义边界、角色、标点、时间间隔和上限生成最终 paragraph ID。

实现应以单一的 `YouTubeCaptionSemanticAnalyzer` 作为唯一入口；旧 `YouTubeTranscriptGrouper.cuesIntoParagraphs` 只作兼容门面并委托给 analyzer，禁止 UI、播放 VM 或缓存层各写一套清洗规则。

---

## 4. 环境音、语气与不可辨识标注

### 4.1 可识别的括号与边界行为

仅检查内容长度 `1...100` 的以下成对括号，且不跨换行：`[...]`、`［...］`、`【...】`、`(...)`、`（...）`。

圆括号常是正文，因此句中圆括号按「类别 + 证据置信度」决策：完整词表命中的语气/演绎与不可辨识标注可删除，例如 `betaone (whispering) betatwo` 只读 `betaone. betatwo`；音乐、现场反应、环境音、角色、开放语法命中以及未知内容仍 fail-open，例如 `I study (music) theory` 原样朗读。位于 cue 边缘的高置信已知标注照常删除。

方括号类标注可在句中删除；如果标注前后都有正文，在 `speechText` 中用 `. ` 代替，给 TTS 一个可控停顿，避免两边词粘连。

| 类别 | 例子 | `speechText` | 边界 | `speaker` |
|---|---|---|---|---|
| 音乐 / 现场反应 / 环境音 | `[Music]`、`[掌声]`、`[footsteps]` | 删标签；纯事件为 `""` | 前后都是硬边界 | 纯事件清空活动角色 |
| 语气 / 演绎方式 | `(whispering) hello` | `hello` | 标签在边缘时产生边界 | 不创建角色 |
| 不可辨识 | `[inaudible]`、`[___]` | 删标签；纯标签为 `""` | 前后都是硬边界 | 纯事件清空活动角色 |
| 角色类型 | `[narrator] hello` | `hello` | 领头标签创建转轮 | 记录高置信角色 |
| 未知标注 | `[door creaks oddly]` | 原样保留 | 无额外边界 | 不推测 |

事件位于 cue 哪一侧也是角色状态合同的一部分：

- **领头事件**先清空继承角色，再解析后面的角色前缀。因此 `ALICE` 之后出现 `[Music] A new scene` 时，新正文不能继续继承 `ALICE`；`[Music] BOB: Welcome` 则先结束旧场景，再允许高置信的 `BOB` 建立新 turn。
- **尾随事件**允许当前正文保留它已经解析出的角色，但在 cue 结束后清空活动角色。因此 `>> ALICE: Goodbye [Music]` 的 `Goodbye` 仍属于 `ALICE`，下一 cue 不再继承她。
- **纯事件**自身始终是前后硬边界，`speechText = ""`，并立即清空活动角色。

### 4.2 双端类型化清洗计划

iOS 与 Android 不再让括号正则直接决定删除，而是先为每个候选建立 `SemanticLabelSpan`，再由统一策略投影 `speechText`。该中间结构只存在于 analyzer 内部，不改变公开缓存模型：

```text
SemanticLabelSpan
  inputRange: NSRange            // 当前语义阶段输入的 UTF-16 范围
  rawText / normalizedText
  category: music | audienceReaction | ambientSound | mixedSound |
            delivery | unavailable | role | unknown
  position: entireCue | leading | inline | trailing
  disposition: suppress | extractSpeaker | preserve
  evidence: exactTaxonomy | unavailableTimestamp | unavailablePlaceholder |
            composedEventGrammar | ambientEventGrammar | musicNotation | unknown
  confidence: high | medium | unknown
  decisionReason: classifiedAccessibilityMetadata | leadingRole |
                  inlineRoleAmbiguity | inlineParentheticalAmbiguity | unknownFailOpen
  role: String?
```

不变量如下：

- `unknown` 必须是 `preserve`，括号形状本身不是删除证据；
- `role` 只有在领头/整 cue 时才 `extractSpeaker`，句中角色标签保留；
- 事件类删除后才可清空 dialogue context，`delivery` 不得清空角色；
- 开放环境音语法是 `medium`，不得借此删除句中圆括号普通旁注；
- downstream 的边界与角色状态从 span 计算，不再维护独立、可能互相矛盾的 event 布尔分类。

`inputRange` 只保证指向本次清洗阶段的输入；第二遍标签处理发生在角色前缀已投影后的文本上，因此它不是原 cue 坐标。端到端 `speechText → 原 cue` 映射会改变时间投影、paragraph ID、音频缓存与恢复进度，必须作为下一版语义合同同时在 iOS / Android 引入，不能单端偷改 Schema 3。

### 4.3 Semantic Schema 3 完整多语词表与开放事件语法

所有标签先做 **Unicode NFKC + locale-independent lowercase + 空白折叠**。以下固定集合以精确匹配为主；Schema 3 另外通过下述 noun/activity 组合语法识别开放集环境音，不依赖具体视频样例。

#### 音乐 `musicLabels`

```text
music, background music, instrumental, singing,
音乐, 音樂, 背景音乐, 背景音樂, 歌声, 歌聲,
音楽, bgm,
música, música de fondo, cantando,
musique, musique de fond,
musik, hintergrundmusik,
música de fundo,
musica, musica di sottofondo,
संगीत, पृष्ठभूमि संगीत
```

#### 现场反应 `reactionLabels`

```text
laughter, laughing, laughs, chuckles, applause, clapping, cheering, audience laughter,
笑声, 笑聲, 笑い声, 笑い,
掌声, 掌聲, 拍手, 欢呼, 歡呼, 歓声,
risas, risa, aplausos,
rires, rire, applaudissements,
gelächter, lachen, applaus,
risadas, risos,
risate, applausi,
हँसी, तालियाँ
```

#### 环境音 `ambientLabels`

```text
coughing, coughs, sigh, sighs, breathing, gasps, gasping,
footsteps, door slams, door closes, door opens, phone rings, ringing,
thunder, explosion, crowd noise, background noise, wind, rain, traffic noise,
咳嗽, 叹气, 嘆氣, 喘息,
脚步声, 腳步聲, 关门声, 關門聲, 电话铃声, 電話鈴聲,
雷声, 雷聲, 爆炸声, 爆炸聲, 人群声, 人群聲, 雨声, 雨聲,
咳, ため息, 息遣い, 足音, ドアの音, 電話の音, 雷, 爆発音,
tos, suspiro, respiración, pasos, trueno, explosión,
toux, soupir, respiration, pas, tonnerre, explosion,
husten, seufzen, atmen, schritte, donner, explosion,
tosse, suspiro, respiração, passos, trovão, esplosione,
खाँसी, आह, साँस, कदमों की आहट, गरज, विस्फोट
```

#### 语气 / 演绎 `deliveryLabels`

```text
whispering, whispers, shouting, yelling, screaming, softly, quietly,
sarcastically, crying, mumbling,
低声, 低聲, 耳语, 耳語, 小声, 小聲, 喊叫, 尖叫,
轻声, 輕聲, 讽刺地, 諷刺地, 哭泣,
ささやき, 小声で, 叫ぶ, 悲鳴, 泣きながら,
susurrando, gritando, en voz baja, llorando,
chuchotant, criant, doucement, en pleurant,
flüsternd, schreiend, leise, weinend,
sussurrando, gridando, piano, piangendo,
फुसफुसाते हुए, चिल्लाते हुए, धीरे से, रोते हुए
```

#### 不可辨识 `unavailableLabels`

```text
inaudible, unintelligible, indistinct speech, audio unclear, crosstalk,
听不清, 聽不清, 无法听清, 無法聽清, 语音不清, 語音不清,
聞き取れない, 不明瞭,
ininteligible, audio poco claro,
incompréhensible, audio indistinct,
unverständlich, undeutlich,
inaudível, ininteligível,
non udibile, incomprensibile,
अस्पष्ट, सुनाई नहीं दे रहा
```

另外两类也视为 unavailable：

- 归一化后仅由至少两个 `_` 组成的标签，如 `[___]`。
- 上述不可辨识词 + `H:MM` / `HH:MM` 时间后缀，如 `[inaudible 01:23]`。

#### 角色类型 `roleLabels`

```text
narrator, host, guest, speaker, interviewer, interviewee, moderator,
man, woman, male voice, female voice, voiceover, voice-over,
旁白, 主持人, 嘉宾, 嘉賓, 说话者, 說話者,
男声, 男聲, 女声, 女聲,
ナレーター, 司会, ゲスト,
narrador, narradora, presentador, presentadora, invitado, invitada,
narrateur, narratrice, animateur, animatrice,
erzähler, erzählerin, moderatorin, sprecher, sprecherin,
narratore, narratrice, conduttore, conduttrice,
वाचक, मेज़बान
```

#### 组合事件词

像 `[upbeat music]`、`[music playing]`、`[laughter and applause]` 不需要枚举整句。当标签中每个空白 token 都属于「基础事件词 + 下列词」，且至少含一个基础事件词时，归为 event。

```text
eventModifiers:
background, soft, softly, quiet, quietly, upbeat, dramatic, suspenseful,
gentle, loud, distant, faint, audience, crowd,
背景, 轻柔, 輕柔, 欢快, 歡快, 激昂, 远处, 遠處

eventLinkWords: and, with, y, et, und, e
eventActivityWords: playing, plays, continues, starts, stops, fades, fading
```

「基础事件词」仅指 `musicLabels | reactionLabels | ambientLabels`；`deliveryLabels` 不参与组合事件推导。

Schema 3 的开放事件语法要求同时命中一个环境实体与一个活动词，且所有 token 都必须属于 `ambientEventNouns | ambientEventActivities | ambientEventQualifiers | eventModifiers | eventLinkWords | eventActivityWords`。例如 `[birds chirping]`、`[door creaking]`、`[speaking foreign language]` 静音；`[Project Update]` 因不满足语法而 fail-open 保留。这是一套「实体 + 活动 + 受限修饰词」的类别语法，不得为了某条视频逐句追加完整短语。

```text
ambientEventNouns:
bird(s), door(s), phone(s), baby/babies, engine(s), audience, crowd, people,
dog(s), cat(s), wind, rain, thunder, traffic, footstep(s), bell(s), alarm(s),
siren(s), glass, gunshot(s), fireworks, water, waves, car(s), train(s),
airplane(s), laughter, applause, music, voice(s), speech, language

ambientEventActivities:
chirping, tweeting, creaking, slamming, closing, opening, ringing, crying,
revving, applauding, clapping, cheering, laughing, barking, meowing, howling,
blowing, falling, raining, rumbling, honking, beeping, buzzing, whistling,
crashing, breaking, firing, exploding, splashing, flowing, roaring, passing,
approaching, departing, singing, speaking, talking, shouting, screaming,
coughing, breathing, gasping

ambientEventQualifiers:
foreign, indistinct, unintelligible, background, distant, nearby, loud, soft,
multiple, several, continuous, language, noise, sound, sounds
```

#### 兼容性词表（角色拒绝、编号角色）

角色拒绝词与可编号角色词的完整集合见 5.2，它们也是 Semantic Schema 3 的一部分。

---

## 5. 角色识别与标签剥离

### 5.1 证据优先级

从强到弱：

1. **结构化格式证据**：WebVTT `<v Name>` 等由字幕格式直接给出的 `cue.speaker`。
2. **已知角色类型**：领头 `[narrator]`、`[主持人]` 等 `roleLabels`。
3. **显式转轮**：`>> ALICE:`、`>> Alice:`。
4. **文本重复证据**：同一 `Name:` 在至少两个独立发言 episode 中出现。多个 rolling caption 快照即使跨 cue，也只能算一次。
5. **Q/A 成对证据**：`Q:` 与 `A:` 同时出现时，两者都可视为角色。

对于非显式转轮的一次性 `Alice: this appears once`，保留整句并让 `speaker = null`。这个保守性是故意的：它避免把 `Note:`、`API:`、`To summarize:`、URL 和时钟当成人名。

### 5.2 候选值硬限制

`Name:` / `Name：` 只在第一个冒号之前取候选值，必须同时满足：

- 非空，最多 32 个 Unicode 字符，最多 4 个空白 token，且含字母。
- 不含 `/ @ = + # > <`，归一化后不是 `http` / `https`，token 中也不含它们。
- 含数字时，只允许两个 token 的「可编号角色词 + 纯数字」，如 `Speaker 2`。
- 不是下面任一拒绝词，且候选中的任一 token 也不是拒绝词。

```text
deniedSpeakerLabels:
chapter, section, part, step, note, warning, example, question, answer,
summary, agenda, tip, definition, reason, result, source, title, topic,
date, time, url, api,
章节, 章節, 部分, 步骤, 步驟, 注意, 示例, 标题, 標題, 主题, 主題,
capítulo, sección, seção, chapitre, abschnitt, kapitel, capitolo, sezione

numberedRoleLabels:
speaker, voice, person, man, woman, host, guest,
说话者, 說話者, 角色, 人物, sprecher, sprecherin
```

显式 `>>` 转轮下，人名形状还需满足任一条：

- 字母数至少 2，并且全大写；或
- 1...4 个 token 均为 Title Case（每个 token 的首个字母有大小写且为大写；`de`、`van` 等非首位 name particle 可保留小写）。

### 5.3 转轮与活动角色

- 识别出的角色在后续无明确角色的 cue 中继续生效。
- 明确新角色会强制新 utterance。
- 无名 `>>` 表示转轮，清空活动角色，但不把后面任意冒号前正文猜成名字。
- 纯环境音/不可辨识段清空活动角色，防止新场景沿用旧人名。
- `>>` / `＞＞` 只有位于 cue/行首，或位于一个完整终止句之后时，才是 turn marker；前后普通正文中的同形字符是运算符或文本。`Use x >> A: first`、`Use x >> 1 and y >> 2` 都必须保持正文。
- 单 cue 中只在有效 marker 后有合法角色候选，或无名 marker 前已有完整终止句时，才分解多轮对话。一个冒号候选也只能从 cue/行首、有效 marker 后或完整终止句后开始，不能从任意操作数中间开始。
- `cue.speaker` 只做空白折叠与非空校验，最长 128 字符；不用文本候选的 32 字符规则反向否定格式自带的证据。

### 5.4 独立证据 episode、非人物标题与 blocked alias

角色识别必须分成「宽松发现语法候选」和「保守确认角色」两步。发现 `Name:` 不等于允许剥离；只有文档级 `SpeakerRegistry` 确认后，前缀才可从 `speechText` 删除。

重复证据按发言 episode 计数，而不是按传输 cue 数量计数。对同一归一化候选，按 `startMs`、输入顺序排序；若当前观察落在前一观察的安全结束时间 `+250ms` 内，并且两段 payload 互相包含，或存在至少 3 token 的 rolling 前缀/后缀窗口，则两者属于同一 episode，只投一票。这样两次逐字扩展的 `Alice: today we are...` 不会伪造“两次独立出场”。所有时间加法都必须饱和或做溢出保护。

重复本身不是人物证据。`User`、`Status`、`Input`、`Output`、`System`、`Model`、`API`、`CPU`、`GPU`、`Chapter`、`Question` 等常见状态、实体、技术缩写和篇章标题属于 `nonPersonHeadingLabels`；其归一化 token 也进入拒绝集合。命中这些语义类别的键必须加入 `blockedKeys`，即使重复出现、位于标签之后或 marker 之后，也不能靠上下文被重新晋升为角色。

首字母缩写与长姓名通过 initials key 建立候选别名，但遵守以下安全规则：

- 缩写是单 token、2...4 个大写字母。没有结构化 `speaker` 或有效 marker 时，它必须在至少两个独立 episode 中出现，而且 payload 必须是 **speech-shaped**：含可朗读字符，并且以完整终止符结束或至少有 4 个词。
- 长姓名一侧必须有自己的 speech-shaped 文档观察；别名边不能让两个弱候选互相“抬升”为角色。
- 同一缩写若对应多个 plausible long form，例如 `MC` 同时对应 `Mary Clark` 与 `Michael Chen`，则该缩写进入 `blockedKeys`，不得猜测归属。
- 长形式含非人物标题 token 时，长形式及其缩写一起阻断。因此 `Machine Learning:` 与重复的 `ML:` 保留为正文。

任何 blocked 或歧义结果都 **fail-open**：保留原 `Name:` 前缀进入 TTS，并令 `speaker = null`，不得为了减少朗读标签而误删正文。

### 5.5 结构化角色与文本前缀冲突

结构化 `cue.speaker` 的可信度高于文本猜测。文本前缀与结构化角色归一化后一致时，可以安全剥离；两者冲突时，不得把正文强行归给文本角色，也不得静默删除冲突前缀。比如 `cue.speaker = Alice`、`text = "Bob: hello"` 的结果必须保留 `speechText = "Bob: hello"`，同时维持 `speaker = Alice`。这是保留信息的 fail-open 行为。

### 5.6 开场制作署名不是角色

制作署名只在开场窗口内识别：输入序号 `0...4`，且 `startMs` 位于 `0...15000`。整个 cue 必须从已知本地化制作字段开始并完整满足 field/value grammar，前面不能混有正文；不能仅凭 `Reviewer:`、`Translator:` 等一个词就静音。

- 多字段记录（如 `Transcriber: Tijana Mihajlović Reviewer: Denise RQ`）只有在每个 value 都通过姓名形态校验时才是 metadata。
- 单字段只有明确 byline 字段（字段含 `by`，或 transcriber / translator / subtitle editor 及其本地化等）才可成立。
- value 必须含可朗读字符、长度不超过 80、为 1...8 个 token、不含终止标点，只允许字母、数字、空白和姓名常见连接符；还要拒绝 `press`、`continue`、`this`、`is` 等常见正文词，并满足大小写姓名形态。当前无大小写形态的自由文本保守地 fail-open。
- `Translator: Press Continue`、`Transcriber: This Is A Test`、`翻译：把这句话翻译成英文` 都是正文，不得静音；晚于开场窗口的同形内容也一律按正文处理。

确认的制作 metadata 保留在 `text`，但 `speechText = ""`、`speaker = null`，并作为前后硬边界清空活动角色。

---

## 6. Rolling caption 去重

rolling caption 是持续更新的可见窗口，例如：

```text
today we are learning how to code
learning how to code with Swift
how to code with Swift safely
```

最终只应朗读 `today we are learning how to code with Swift safely`，但每个 cue 的可见文本仍保留。

### 6.1 允许比较的前置条件

仅当以下条件全部成立时尝试去重：

- 前后 `speaker` 完全相同（包括同为 `null`）。
- 前一 cue 没有 `boundaryAfter`，当前 cue 没有 `boundaryBefore`。
- 两 cue 在时间上可能是同一 rolling 窗口：
  - 任一 `durationMs == 0`时：`current.startMs >= previous.startMs` 且差值 `<= 1000ms`。
  - 两者都有 duration 时：`current.startMs <= previous.safeEndMs + 250ms`。

`safeEndMs = startMs + clamp(durationMs, 0, 30000)`，必须做 64 位溢出保护。

### 6.2 匹配阈值

对空格语言，匹配「前 cue token 后缀」与「当前 cue token 前缀」，从最长到最短尝试；至少 3 token，NFKC + lowercase 后拼接长度至少 12 字符，并且至少 2 个不同 token。因此 `no no no` 接 `no no no` 不会被当作 rolling overlap。

仅在前后文本都含 CJK/Kana 时，才回退到字符后缀/前缀比较：至少 6 字符，且至少 3 个不同字符。

### 6.3 连续窗口

比较基准必须保留「上一个完整 rolling 窗口 + 本次新增后缀」，不能只记住本次新读的词。完全重复的 cue 也要推进比较时间窗口。

被抑制的重复内容只从 `speechText` 消失；它的 `text` 会并入当前显示段，时间终点也继续向后推进。

---

## 7. 基于标点与时间的 utterance 断句

### 7.1 cue 内自然句

硬终止符是 `. ! ? ; 。 ！ ？ ； … । ॥`。标点后可吸收以下闭合符再切段：`" ' » ’ ” ) ] ） 】 」 』 〉 》`。

仅当终止符后是字符串结尾、空白、CJK 或 Kana 时切分，因此 URL / 小数内部的点不会因后续拉丁字母而直接切开。

句末 `.` 还需做缩写保护：去掉点后的末 token 若只有一个字母，或属于下表，不视为句末。

```text
abb, bsp, bzw, ca, dr, e.g, etc, ggf, i.e, inkl, kap, mr, mrs, ms,
nr, prof, s, sog, st, u, u.k, u.s, a.m, p.m, ph.d, usw, vgl, vs, z
```

### 7.2 硬上限

任一最终 utterance 必须同时满足：

| 维度 | 上限 | 统计口径 |
|---|---:|---|
| 文本长度 | 240 UTF-16 code units | Swift 用 `NSString.length`；Kotlin 用 `String.length` |
| 词数 | 42 | 按 Unicode whitespace 分词 |
| 时间跨度 | 15000ms | 从本段首 cue `startMs` 到末 cue `safeEndMs` |

切分顺序：先用自然句末，再对过大句按词切。没有空格且仍超过 240 UTF-16 时按 Unicode grapheme 切；如果单个扩展 grapheme 本身就超限，必须再按 scalar 安全切，不得崩溃或让 TTS 输入无上限。

对超长 duration cue，期望分块数是 `ceil(clamp(durationMs, 0, 30000) / 15000)`。若自然句数量仍不足，优先从最长块中点按词切；单词也按 grapheme 中点切，确保时间上限不是软建议。

将一个 cue 切成多块时，用 `speechText` UTF-16 长度按比例分配 `startMs/durationMs`。显示文本先尝试将 speech chunk 反查回原显示文本；因标签删除无法反查时，在最近空白/标点处按比例切分，必须保留所有可见字符。

### 7.3 跨 cue 合并与切断

假设 `gap = next.startMs - current.safeEndMs`。任一条成立就开始新 utterance：

1. 当前 cue 有 `boundaryBefore`，或已累积段有 `boundaryAfter`。
2. `speaker` 变化，包括 `null ↔ 非 null`。
3. `gap >= 1200ms`。
4. `gap >= 600ms`，且已累积 `speechText` 至少 100 UTF-16，或它以软边界 `, ， : ： — –` 结尾。
5. 合并后会超过 240 UTF-16、42 词或 15000ms 时间跨度。
6. 前一个 speech chunk 以本节的硬终止标点结尾，且不是缩写。

`gap == 1200ms` 必须切，`1199ms` 不因该规则切。负 gap 是合法的重叠字幕，不单独构成边界。

合并文本时，前后都是 CJK/Kana 则不加空格，其他情况加一个空格。纯环境音段作为独立 paragraph 保留，`speechText = ""`，并硬切断前后场景。

---

## 8. UI、TTS 和高亮合同

```text
cues
  ↓ YouTubeCaptionSemanticAnalyzer
paragraph.text --------------------------> 静态字幕显示
paragraph.resolvedSpeechText → TTS → AudioSegment.text/timestamps
paragraph.speaker -----------------------> 角色标签 + 段落边界
```

硬规则：

- 可播放段落必须用 `containsSpeakableContent(resolvedSpeechText)` 判定，不得用 raw `text`。
- TTS 请求、预取、缓存 audio 的 `originalText`、失败重试全部使用 `resolvedSpeechText`，不得在 VM 某一条支路回退到 raw `text`。
- 通用 `SpeechTextSanitizer` 可作最后一层防御，但不得代替 YouTube 语义处理器；它不掌握角色转轮、rolling 时间窗口和 raw/speech 双文本合同。
- 静态时显示 `paragraph.text`。当前正在播放的段落可显示 TTS 返回的 processed text 做词级高亮；若角色前缀已从 processed text 消失，用独立 speaker label 保留「谁在说」。
- 高亮以 `AudioSegment.timestamps` 在它自己的 processed TTS text 上定位，**不将 timestamp 反映射回 raw `text`**。环境音和角色标签不在音频中，本来就没有可高亮时间。
- 纯事件 paragraph 显示但自动跳过 TTS、预取和免费额度计费。
- `AudioSegment.speaker` 应携带 paragraph speaker，但 P0 的 voice 选择仍只看用户选择与朗读语言。

---

## 9. 缓存 schema 与迁移

### 9.1 三个版本不要混为一个

| 版本 | 作用 | 当前规则 |
|---|---|---|
| `captionSemanticSchemaVersion` | cue → paragraph 语义合同 | 跨端同为 `3` |
| `YouTubeTTSAudioCacheSchema` | 本端持久化 AudioSegment 格式/内容 | 语义输出改变时必须加 1；iOS 为 `7`，Android 为 `9` |
| transcript / manifest schema | 容器和文件布局 | 只在容器格式变化时升级 |

两端本地 audio schema 无需数字相同；真正需要跨端相同的是 `captionSemanticSchemaVersion = 3` 和派生结果。

### 9.2 原始 transcript

- transcript fingerprint 继续以 cue 的 `startMs + durationMs + text` 为核心，不因派生分段改变。有非空结构化 `speaker` 时将它追加到指纹；无 speaker 的旧数据保持旧指纹。
- `paragraphs` 是派生数据。从缓存 decode 时必须一律用 `cues` 和当前 analyzer 重新生成，不信任文件里旧的 paragraph ID / text。
- 旧 cue 没有 `speaker` 时解码为 `null`；旧 paragraph 没有 `speechText/speaker` 时也必须能解码。
- 旧 transcript 缺 `captionSemanticSchemaVersion` 时，在线打开先尝试重新提取，以补回旧展平文本无法恢复的 WebVTT `<v>` 证据；无网或重新提取失败时，允许用 raw cue 重新派生的安全回退。
- 在线刷新旧缓存时按“字幕语言 + manual/ASR”严格选轨；即使旧缓存没有 stable track ID，也不得退回首次打开的 ranked fallback。刷新失败时，只能回退同语言、同 kind 的旧缓存。

### 9.3 TTS 音频与进度

- 旧 audio 可能真的朗读了 `[Music]` 和 `ALICE:`，也可能指向不同 paragraph ID，因此必须通过新 audio schema key 整体失效，不做文本相似就复用。
- paragraph-index progress 必须携带 `semanticSchemaVersion`。缺失或不等于当前版本时不恢复旧 paragraph/segment 位置，也不猜测映射。
- 不要删原始 transcript、缩略图和 storyboard；它们与语义音频版本独立。

### 9.4 以后修改规则的发布顺序

1. 先增加或更新两端共享 golden vectors。
2. 同时升级 `YouTubeCaptionSemanticSchema`。
3. 两端各自升级 TTS audio cache schema。
4. 保持旧模型字段可解码，并验证旧进度不会应用到新 paragraph ID。
5. 直到两端同一向量结果一致才可宣布对齐。

---

## 10. 跨端确定性约束

- 时间一律用有符号 64 位毫秒整数；所有加法做溢出保护。
- 长度上限按 UTF-16 code unit，不按 Swift grapheme count 或 UTF-8 byte count。
- lowercase 必须 locale-independent；Android 用 `Locale.ROOT`，禁止让土耳其语系统 locale 改变 `I/i` 结果。
- 标签归一化是 NFKC；空白判定用 Unicode whitespace。
- CJK/Kana 范围为 `U+3400...U+9FFF`、`U+3040...U+30FF`、`U+31F0...U+31FF`；可朗读性额外支持 Hangul `U+AC00...U+D7AF` 与 Devanagari `U+0900...U+097F`。
- 同时间 cue 必须 stable sort；Set/Map 的迭代顺序不得影响结果。
- 只有 `speaker == speaker` 才能 rolling 去重；不做大小写或别名模糊合并。
- 最终 paragraph ID 必须在所有切分、抑制和事件段落处理完后，按输出顺序从 0 重排。

---

## 11. 测试矩阵

单元测试必须同时断言 raw 显示、speech、speaker、起始时间和 paragraph ID，不能只断言「段落数量大于 0」。

| 类别 | 必测输入 | 关键期望 |
|---|---|---|
| 纯事件 | `[Music]`、`【掌声】`、`[inaudible 01:23]`、`[___]` | raw 保留，speech 为空，独立边界，不可播放 |
| 语气 | `(whispering) Keep quiet` | raw 保留，只读 `Keep quiet` |
| 连续/组合标签 | `(laughing) (whispering) Keep quiet`、`[upbeat music]`、`[laughter and applause]` | 多标签全处理，组合事件不朗读 |
| 保守误删 | `I study (music) theory`、`The word [man] appears` | 原样朗读，不创建 speaker |
| 歌词 | `♪ We are alive ♪` | raw 保留，只读 `We are alive` |
| 标签后角色 | `[Music] ALICE: Hello`、`>> [Music] ALICE: Hello` | 只读 `Hello`，speaker `ALICE` |
| 事件位置与角色状态 | `ALICE` → `[Music] A new scene`；`ALICE: Goodbye [Music]` → `A new scene`；`[Music] BOB: Welcome` | 领头/尾随事件都终止继承；事件后的高置信新角色仍可建立 turn |
| 开放环境音语法 | `[birds chirping]`、`[door creaking]`、`[speaking foreign language]`、`[Project Update]` | 前三项按 noun+activity 静音；未知标题 fail-open 原样朗读 |
| 单 cue 多个 WebVTT voice | `<v Alice>Hi</v><v Bob>abcdefgh</v>`；`Intro <v Alice>Hello</v>` | 完整覆盖时拆为两个 cue 并按文本权重投影时间；存在无归属正文时保留一条 speaker=null 的完整 cue |
| 结构化角色 | 连续 `Alice/Alice/Bob` cue | 前两个合并，Bob 开新段 |
| 结构化角色冲突 | `cue.speaker = Alice` + `Bob: hello` | 保留 `Bob: hello` 进入 speech，speaker 仍为 `Alice` |
| 文本角色 | `>> ALICE: Hi`、`>> Alice: Hi`、两次 `Alice:`、Q/A 成对 | 剥离前缀，保留 speaker |
| 一次性冒号 | `Alice: once`、`Note: heading`、`API: failed`、`10:30`、`https://...` | 全文保留，speaker 为 null |
| Marker 位置语法 | cue/行首 `>> ALICE:`、完整终止句后 `>> BOB:`、正文中的 `>>` | 只有前两类 marker 可建 turn；正文运算符保持原样 |
| 带冒号的位移操作数 | `Use x >> A: first. Use y >> B: second.`、`Use x >> 1 and y >> 2` | 不分 turn，不剥离 `A:` / `B:` |
| 单 cue 多轮 | `>> ALICE: Hi. >> BOB: Hello.`、`>> Hello. >> BOB: Hi.` | 两段，无名转轮不泄漏 marker |
| Rolling 角色计票 | `Alice: today we are...` → 同窗口扩展 | 只算一个独立 episode，不能靠两个传输快照确认角色 |
| 非人物标题 | 两次 `User:`、两次 `Status:` | 全文保留，speaker 为 null |
| 技术长名/缩写 | `Machine Learning:` + 两次短 payload 的 `ML:` | 长名和缩写均 blocked，全部保留朗读 |
| 缩写 speech-shaped 证据 | 独立重复 `DB: This is a complete utterance.` | 只有终止句或至少 4 词的独立 payload 才能作为弱缩写证据 |
| 歧义首字母 | `Mary Clark:`、`Michael Chen:`、两次 `MC:` | `MC` 不绑定任一长名；所有弱前缀 fail-open 保留 |
| 开场制作署名 | `Transcriber: Rhonda Jacobs`、多字段署名记录 | raw 保留、speech 为空、speaker 为 null，并切断前后角色 |
| 署名正文 fail-open | `Translator: Press Continue`、`Transcriber: This Is A Test`、`翻译：把这句话翻译成英文` | 原样朗读，不能因字段名静音 |
| rolling 两/三窗口 | `...how to code` → `how to code with Swift` → `...safely` | speech 每个词只一次，raw 仍完整 |
| rolling 完全重复 | A → A → A+新后缀 | 中间 cue 推进时间窗口，新后缀仍正确 |
| 短词重复 | `no no no` → `no no no` | 不去重，两组都读 |
| 硬时间边界 | 1199ms / 1200ms gap | 1199 可合并，1200 必切 |
| 软时间边界 | 600ms gap + 100 UTF-16，或逗号/冒号/破折号 | 条件满足时切，599ms 不因该规则切 |
| 句末 | 一 cue 内各种硬终止符 | 每个自然句独立 utterance |
| 缩写 | `Dr. Smith`、`U.S. market`、`e.g. example` | 缩写点不产生假句末 |
| CJK 连接 | `你好` + `世界。` | 合并时不插入空格，句号后切 |
| 硬上限 | 60 词、>240 UTF-16、无空格超长文本 | 每段均不越界，拼回后不丢词 |
| 极端 grapheme | 基字母 + 300 个 combining mark | 不崩溃，每段最多 240 UTF-16 |
| 持续时间 | 30000ms 长句、不均衡多句、无空格单词 `helloworld` | 都至少两块；递归拆最长块，单词按 grapheme 中点切，时间按 UTF-16 比例递增 |
| 整数边界 | `startMs` 接近 Int64 max + 巨大 duration | 不溢出/崩溃，起始时间保留 |
| 旧模型 | JSON 缺 cue speaker / paragraph speechText / semantic schema | 能 decode，paragraph 从 cue 重建，旧进度不恢复 |
| 缓存 | 同 raw fingerprint 下的旧 audio schema | 旧 audio 不命中，新 audio 可按 paragraph 稳定回放 |
| UI / 高亮 | 当前段 raw 含 `[Music] ALICE:` 但 audio 只含 `Hello` | speaker 仍可见，高亮只跟 processed TTS text，不越界 |

跨端 golden test 应对同一输入数组比较完整输出 JSON，而不是两端各自写「看起来差不多」的断言。

当前 golden fixture 的同步路径：

- iOS：`docs/contracts/youtube-caption-semantics-v3.json`
- Android：`app/src/test/resources/contracts/youtube-caption-semantics-v3.json`

两份文件是镜像，评审或 CI 应先比较文件字节，再分别在两端运行 fixture test。

---

## 12. P0 验收门槛

- [x] Android 和 iOS 的 semantic schema 同为 3，模型具有 raw/speech/speaker 三轨。
- [x] WebVTT 结构化 voice 从提取到 cache 不丢失。
- [x] 两端以本文固定顺序生成相同 paragraph 列表。
- [x] TTS、预取、重试、audio cache 全程只吃 `resolvedSpeechText`。
- [x] 纯环境音显示但不朗读；角色前缀不朗读；rolling 内容不重读。
- [x] 角色确认只依赖结构和文档级 episode；blocked/歧义/结构化冲突一律 fail-open，不误删正文。
- [x] 开场制作署名只按完整 field/value grammar 静音，字段名后普通正文不被吞掉。
- [x] 断句同时遵守标点、1200/600ms 间隔和 240/42/15000 上限。
- [x] UI 保留 raw 语义与 speaker，高亮跟 processed TTS text 不错位。
- [x] 旧 audio 和旧 paragraph-index progress 不会误用到新分段。
- [x] iOS YouTube 子集、Android YouTube 全回归以及双端 app 构建均通过。
- [ ] 发布说明明确：P0 能识别高置信多角色并分段，**但不会自动为不同角色切换音色**。

### 12.1 代码落点

| 合同节点 | iOS | Android |
|---|---|---|
| cue / paragraph / semantic schema | `CastReader/Models/YouTubeTranscript.swift` | `youtube/model/YouTubeModels.kt` |
| 语义处理器 | `YouTubeCaptionSemanticAnalyzer` | 对齐的 `YouTubeCaptionSemanticAnalyzer` |
| WebVTT voice 提取 | `CastReader/Services/YouTubeWebScripts.swift` | `assets/youtube/youtube-extraction-adapter.js` + envelope decoder |
| raw 展示 / processed 高亮 | `Views/YouTube/YouTubeListenView.swift` | `youtube/ui/YouTubeListenScreen.kt` |
| TTS 输入与 speaker 传递 | YouTube 朗读 VM / `AudioSegment` | `YouTubeListenViewModel.kt` / playback paragraph bridge |
| transcript / audio / progress 迁移 | `Services/YouTubeCacheStore.swift` | `youtube/cache/YouTubeCacheStore.kt` 及 persistence contracts |

新增的 Android 代码不应在通用文档朗读模块里复制整套 YouTube 词表；平台桥接只负责把 analyzer 已产出的 `resolvedSpeechText/speaker` 传入既有 TTS 和播放管线。
