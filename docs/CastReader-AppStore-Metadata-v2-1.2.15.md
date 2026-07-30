# CastReader · App Store 元数据 v2（随 1.2.15 提交）

> 基线文档：`CastReader-AppStore-Metadata-8-Languages.md`（v1，1.2.14 及以前）。
> 本文只列**变更字段**与**新增语言**；未列出的字段（描述正文、What's New 等）沿用 v1。
> 所有字段已机器校验：名称/副标题 ≤30 字符、关键词 ≤100 字符、推广文本 ≤170 字符。
>
> ⚠️ **执行时机**：关键词/副标题是版本锁定字段，**只随 1.2.15 提交**；1.2.14 正在审核，别碰它的任何元数据。
> 推广文本不锁版本、免审——已于 2026-07-27 直接推到线上（见文末记录）。

## 0. 修订逻辑（为什么这么改）

1. **名称↔副标题去重**：en 的 "read aloud"、ja 的「読み上げ/AI/解説」在两个最高权重字段重复——重复词不叠加权重，纯浪费。副标题全部改为承载**新增 token**。
2. **最高量词升仓**：`text to speech` 从最弱的关键词字段升到 en 副标题（Speechify 同款做法）。
3. **组合覆盖**：Apple 跨字段组词。v2 后 en 的 token 池 = castreader/read/aloud/ai/text/speech/pdf/web + 15 个关键词 token，可组合命中 `listen to pdf`、`pdf to speech`、`dyslexia reader`、`study reader` 等长尾。
4. **三个结构缺口**：
   - **de-DE 商店页不存在**（九语 App，德区用户看英文页）→ 新增全套；
   - **zh-Hant 缺失**（TW/HK 已上架却回退英文页；zh-Hans 服务的 CN 未上架）→ 新增全套；
   - **hi 关键词只用了 33/100**→ 补满。
5. **美区索引扩容**（业界验证的机制）：美区商店同时索引 `en-US` + `es-MX` + `zh-Hans` 的关键词字段。zh-Hans 尾部和新增 es-MX 的关键词字段填**英文增量词**（summary/textbook/paper/news/notes/narrator…），等于给美区多出 ~170 字符索引位。CN 上架时再把 zh-Hans 换回纯中文即可。
6. **ASA 闭环**：投放两周后用搜索词报告里的高转化词替换低效词——本表是起点不是终点。

## 1. 变更字段总表

| locale | 副标题（新） | 关键词（新） |
|---|---|---|
| en-US | `Text to Speech for PDF & Web` | `tts,listen,audiobook,voice,reader,ocr,scan,epub,ebook,book,article,dyslexia,adhd,study,document` |
| zh-Hans | 不变 | `听书,文字转语音,英语听力,有声书,网页阅读,文档,学习,无障碍,summarize,textbook,paper,news,notes` |
| ja | `PDF・Web・本を音声で聴く` | `テキスト読み上げ,朗読,オーディオブック,音声合成,リスニング,勉強,論文,電子書籍,リーダー,OCR,教科書,ニュース,英語` |
| es-ES | `Escucha PDF, web y libros` | `tts,ocr,leer,lector,audiolibro,ebook,epub,estudio,resumen,dislexia,documentos,aprender,escanear` |
| fr-FR | `Écouter PDF, web et livres` | `tts,ocr,lire,lecteur,voix,haute,livre audio,ebook,epub,étude,résumé,dyslexie,document,apprendre` |
| pt-BR | `Ouvir PDF, web e livros` | `tts,ocr,ler,leitor,audiolivro,ebook,epub,estudo,resumo,dislexia,documentos,aprender,escanear` |
| it | `Ascolta PDF, web e libri` | `tts,ocr,leggere,lettore,audiolibro,ebook,epub,studio,riassunto,dislessia,documenti,voce,alta` |
| hi | 不变 | `टीटीएस,ओसीआर,ऑडियोबुक,ईबुक,अध्ययन,पीडीएफ,सुनना,पढ़ना,बोलना,किताब,वेब,अंग्रेज़ी` |

名称全部不变（品牌连续性 + 评分即将开始累积，不折腾）。

另：**所有语言描述里的「8 LANGUAGES/8 种语言」段落随 1.2.15 更新为 9 种（加德语）**——现文案已过时。

## 2. 推广文本 v2（全语言，含 7 天试用；已推线上）

| locale | 文案 |
|---|---|
| en-US | Try Pro free for 7 days. Turn photos, web pages, PDFs, and books into natural speech with synced highlighting — or let AI explain them with handwritten-style notes. |
| zh-Hans | Pro 现可免费试用 7 天。拍照、网页、PDF、电子书一键朗读，同步高亮跟读；AI 还能讲解原文并绘制手写标注。九种语言界面与语音。 |
| ja | Proが7日間無料に。写真、Web、PDF、電子書籍を自然な音声で読み上げ、同期ハイライトで集中。AI解説は原文に手書き風の注釈を表示します。 |
| es-ES | Prueba Pro gratis 7 días. Convierte fotos, webs, PDF y libros en voz natural con resaltado sincronizado, o deja que la IA explique el original con notas manuscritas. |
| fr-FR | Essayez Pro gratuitement 7 jours. Photos, pages web, PDF et livres lus à voix haute avec surlignage synchronisé — ou expliqués par l'IA avec des notes manuscrites. |
| pt-BR | Experimente o Pro grátis por 7 dias. Fotos, páginas, PDFs e livros em voz natural com destaque sincronizado — ou explicados pela IA com notas à mão. |
| it | Prova Pro gratis per 7 giorni. Foto, pagine web, PDF e libri letti con voce naturale ed evidenziazione sincronizzata, o spiegati dall'IA con note a mano. |
| hi | Pro 7 दिन मुफ़्त आज़माएँ। फ़ोटो, वेब पेज, PDF और किताबें प्राकृतिक आवाज़ में सुनें, सिंक हाइलाइट के साथ — या AI से हस्तलिखित नोट्स के साथ समझें। |

## 3. 新增语言 · de-DE（全套）

**Name**：`CastReader: Vorlesen mit KI`
**Untertitel**：`PDF, Web & Bücher anhören`
**Keywords**：`tts,ocr,sprachausgabe,hörbuch,ebook,epub,lernen,studium,zusammenfassung,legasthenie,dokument`
**Promotext**：`Pro 7 Tage gratis testen. Fotos, Webseiten, PDFs und Bücher natürlich vorlesen lassen – mit synchroner Hervorhebung, oder von der KI mit Notizen erklärt.`

**Beschreibung**：

```text
CastReader macht aus jedem Text etwas, das du hören und verstehen kannst.

VORLESEN — KONZENTRIERT BLEIBEN
Verwandle Fotos, Webseiten, PDFs, EPUBs und Texte in natürliche Sprache. Synchrone Hervorhebung und automatisches Scrollen halten Augen und Ohren im selben Satz – beim Lernen, Pendeln, Sport oder wenn du deine Augen schonen willst.

KI-ERKLÄRUNG — MEHR ALS NUR LESEN
CastReader erstellt eine klare Erklärung und liest sie vor, während handschriftliche Anmerkungen auf dem Original erscheinen: Markierungen für Kernaussagen, Kreise um wichtige Begriffe, nummerierte Schritte. Hören, sehen und die Struktur schwieriger Texte verstehen.

EIGENE INHALTE NUTZEN
• Kamera oder Foto: Texterkennung direkt auf dem Gerät
• Web: URL öffnen und sofort anhören
• Dateien: PDF, EPUB, TXT, DOCX und Bilder
• Einfügen: Kopierten Text sofort in Sprache verwandeln
• Kindle: Kindle-Bibliothek verbinden und weiterlesen

GEMACHT FÜR
• Alle, die Artikel, Dokumente und E-Books lieber hören
• Sprachlernende, die eine synchron mitlaufende Anzeige wollen
• Studierende und Berufstätige mit anspruchsvollen Texten
• Alle, die ihre Augen entlasten oder Barrierefreiheit brauchen

9 SPRACHEN
Oberfläche und Sprachausgabe unterstützen Deutsch, Englisch, Chinesisch, Japanisch, Spanisch, Französisch, brasilianisches Portugiesisch, Italienisch und Hindi. Verfügbare Stimmen variieren je nach Sprache.

CASTREADER PRO
CastReader ist jeden Tag kostenlos nutzbar. Mit Pro gibt es unbegrenztes Vorlesen, unbegrenzte KI-Erklärungen, alle Premium-Stimmen und bis zu 3-fache Geschwindigkeit – neue Abonnenten testen 7 Tage gratis.

Dunkelmodus und Hintergrundwiedergabe werden unterstützt. Die Texterkennung von Fotos erfolgt auf dem Gerät, Fotos werden nicht hochgeladen. Der Leseverlauf bleibt auf deinem Gerät.

Nutzungsbedingungen (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
```

## 4. 新增语言 · zh-Hant（全套，服务 TW/HK）

**名稱**：`CastReader：朗讀 · AI解讀`
**副標題**：`拍照·網頁·PDF朗讀，AI講解標註`
**關鍵詞**：`聽書,文字轉語音,英語聽力,有聲書,網頁閱讀,文件,學習,無障礙,課本,論文,唸書,語音`
**推廣文字**：`Pro 現可免費試用 7 天。拍照、網頁、PDF、電子書一鍵朗讀，同步高亮跟讀；AI 還能講解原文並繪製手寫標註。九種語言介面與語音。`

**描述**：

```text
CastReader 把任何文字變成「能聽，也能懂」的內容。

朗讀 — 讓注意力跟上聲音
拍照、網頁、PDF、EPUB、純文字都能轉換成自然語音。同步高亮配合自動捲動，讓眼睛與耳朵停在同一句話上。學習、通勤、運動、做家事或需要護眼時，都能繼續閱讀。

AI 解讀 — 不只讀，更讀懂
CastReader 生成清晰的講解並朗讀，同時在原文上逐筆顯示手寫風標註：高亮重點、圈出關鍵詞、標註步驟。邊聽講解邊看原文，更容易理解複雜資料的結構與邏輯。

匯入你的內容
• 拍照識字：對準書本、文件或螢幕，在裝置上辨識
• 網址：任何網頁直接朗讀或解讀
• 檔案：PDF、EPUB、TXT、DOCX、圖片
• 貼上：複製的文字立即開始聆聽
• Kindle：連接 Kindle 書庫繼續閱讀

適合誰
• 想用「聽」讀完文章、資料、電子書的人
• 需要同步視覺引導的語言學習者
• 處理艱深內容的學生與專業人士
• 需要護眼或無障礙輔助的人

9 種語言
介面與語音支援英文、中文、日文、西班牙文、法文、德文、巴西葡萄牙文、義大利文、印地文。可用音色因語言而異。

CASTREADER PRO
每天都能免費使用。升級 Pro 解鎖無限朗讀、無限解讀、全部進階音色與最高 3 倍速；新訂閱者可享 7 天免費試用。

支援深色模式與背景播放。照片文字辨識在裝置上完成，不會上傳。閱讀記錄只保存在本機。

使用條款（EULA）：https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
```

## 5. 新增语言 · es-MX（美区索引扩容位）

名称/副标题/描述/What's New **全部克隆 es-ES**；唯一差异是关键词字段填英文增量词（该字段被美区索引）：

**Keywords**：`summary,summarizer,textbook,paper,notes,narrator,speak,news,homework,lecture`

## 6. 执行清单（1.2.15 提交时）

1. ASC → App Information：新增 de-DE / zh-Hant / es-MX 三个 localization（名称/副标题按本文）。
2. 每个新 locale 需要**截图**：直接复用现有套图（de 可用 en 套图；zh-Hant 复用 zh 套图或 en）。
3. 1.2.15 版本页：8 个既有 locale 粘贴新副标题/关键词；3 个新 locale 粘贴全套；所有描述的「8 种语言」段落改 9 种。
4. What's New 使用下一节已经审校的 11 语文案。
5. 提交后 2 周：用 ASA 搜索词报告做第一轮换词。

## 7. What's New · 1.2.15（11 个 App Store locale）

### en-US

```text
• Added Google Play Books and Kobo connections: sync your library, then listen to or explain books page by page.
• Kindle now lets you choose your regional website instead of always opening the U.S. site.
• Improved automatic and manual page turns, player consistency, dark mode, localization, and stability.
```

### zh-Hans

```text
• 新增 Google Play 图书和 Kobo 连接：同步书架后，可逐页朗读或解读书籍。
• Kindle 现在支持选择所在地区站点，不再固定进入美国站。
• 优化自动与手动翻页、播放器一致性、深色模式、多语言显示和稳定性。
```

### ja

```text
• Google Play ブックスと Kobo の連携に対応。ライブラリを同期し、ページごとに読み上げ・AI 解説できます。
• Kindle は米国サイト固定ではなく、利用地域のサイトを選べるようになりました。
• 自動・手動ページ送り、プレーヤー、ダークモード、多言語表示、安定性を改善しました。
```

### es-ES

```text
• Añadimos conexiones con Google Play Libros y Kobo: sincroniza tu biblioteca y escucha o pide explicaciones página a página.
• Kindle ahora permite elegir el sitio de tu región en lugar de abrir siempre el de EE. UU.
• Mejoramos el cambio de página automático y manual, el reproductor, el modo oscuro, las traducciones y la estabilidad.
```

### fr-FR

```text
• Connexion à Google Play Livres et Kobo : synchronisez votre bibliothèque, puis écoutez ou faites expliquer vos livres page par page.
• Kindle permet désormais de choisir le site de votre région au lieu d’ouvrir systématiquement le site américain.
• Amélioration du changement de page, du lecteur, du mode sombre, des traductions et de la stabilité.
```

### pt-BR

```text
• Adicionamos conexões com Google Play Livros e Kobo: sincronize sua biblioteca e ouça ou explique os livros página por página.
• O Kindle agora permite escolher o site da sua região, em vez de abrir sempre o site dos EUA.
• Melhoramos a troca automática e manual de páginas, o player, o modo escuro, as traduções e a estabilidade.
```

### it

```text
• Aggiunti i collegamenti a Google Play Libri e Kobo: sincronizza la libreria, quindi ascolta o fai spiegare i libri pagina per pagina.
• Kindle ora consente di scegliere il sito della propria area geografica invece di aprire sempre quello statunitense.
• Migliorati il cambio pagina automatico e manuale, il lettore, la modalità scura, le traduzioni e la stabilità.
```

### hi

```text
• Google Play Books और Kobo कनेक्शन जोड़े गए: अपनी लाइब्रेरी सिंक करें और किताबों को पेज-दर-पेज सुनें या AI से समझें।
• Kindle में अब अमेरिकी साइट के बजाय अपने क्षेत्र की साइट चुनी जा सकती है।
• अपने-आप और मैन्युअल पेज बदलने, प्लेयर, डार्क मोड, अनुवाद और स्थिरता में सुधार किया गया है।
```

### de-DE

```text
• Neu: Verbindungen zu Google Play Books und Kobo. Bibliothek synchronisieren und Bücher Seite für Seite vorlesen oder erklären lassen.
• Bei Kindle lässt sich jetzt die Website der eigenen Region auswählen, statt immer die US-Seite zu öffnen.
• Automatischer und manueller Seitenwechsel, Player, Dunkelmodus, Übersetzungen und Stabilität wurden verbessert.
```

### zh-Hant

```text
• 新增 Google Play 圖書和 Kobo 連接：同步書庫後，可逐頁朗讀或解讀書籍。
• Kindle 現在支援選擇所在地區的網站，不再固定進入美國站。
• 改善自動與手動翻頁、播放器一致性、深色模式、多語言顯示和穩定性。
```

### es-MX

```text
• Agregamos conexiones con Google Play Libros y Kobo: sincroniza tu biblioteca y escucha o pide explicaciones página por página.
• Kindle ahora permite elegir el sitio de tu región en vez de abrir siempre el de Estados Unidos.
• Mejoramos el cambio de página automático y manual, el reproductor, el modo oscuro, las traducciones y la estabilidad.
```

## 附：2026-07-27 已执行

- 推广文本 v2（§2）已通过 ASC API 推到线上 1.2.13 的 8 个 locale（免审，立即生效）——商店页从此有「7 天免费试用」信息，先于 1.2.14 过审。
