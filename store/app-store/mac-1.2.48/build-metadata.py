#!/usr/bin/env python3
"""Derive Mac copy from the released, reviewed 28-language iOS campaign."""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
IOS = HERE.parent / '1.2.48'
ROOT = HERE.parents[2]

# Authored Mac platform paragraph and version-specific release note.
COPY = {
    'en': ['MADE FOR MAC\nRead in desktop windows with a sidebar, keyboard shortcuts, drag-and-drop file import, and sharing to CastReader. Use your existing CastReader account and Pro membership.', 'Now supports 28 interface and reading languages on Mac. Voice lists follow your app language, and voice selection during playback follows the language being read. Improved language switching, reading direction, and cloned-voice balance display.'],
    'zh-Hans': ['为 Mac 打造\n通过桌面窗口、侧边栏、键盘快捷键、拖放文件和分享到 CastReader 进行阅读。沿用现有 CastReader 账号与 Pro 会员。', 'Mac 界面与朗读现已支持 28 种语言。音色列表跟随应用语言，播放中更换音色则跟随正在阅读的语言。改进语言切换、阅读方向与克隆音色额度显示。'],
    'ja': ['MAC のために\nデスクトップウインドウ、サイドバー、キーボードショートカット、ファイルのドラッグ＆ドロップ、CastReader への共有に対応。お使いの CastReader アカウントと Pro メンバーシップをそのまま利用できます。', 'Mac の画面と読み上げが 28 言語に対応しました。音声一覧はアプリの言語に、再生中の音声選択は読んでいる言語に合わせて表示されます。言語切り替え、読み方向、クローン音声の残量表示を改善しました。'],
    'de': ['FÜR DEN MAC\nLies in Desktopfenstern mit Seitenleiste, Tastenkürzeln, Dateiimport per Drag-and-drop und Teilen an CastReader. Nutze dein bestehendes CastReader-Konto und deine Pro-Mitgliedschaft.', 'Oberfläche und Vorlesen auf dem Mac unterstützen jetzt 28 Sprachen. Die Stimmenliste folgt der App-Sprache; die Auswahl während der Wiedergabe folgt der gelesenen Sprache. Sprachwechsel, Leserichtung und Guthabenanzeige für geklonte Stimmen wurden verbessert.'],
    'fr': ['CONÇU POUR MAC\nLisez dans des fenêtres avec barre latérale, raccourcis clavier, importation par glisser-déposer et partage vers CastReader. Retrouvez votre compte CastReader et votre abonnement Pro.', 'L’interface et la lecture sur Mac prennent désormais en charge 28 langues. Les listes de voix suivent la langue de l’app ; le choix pendant la lecture suit la langue du texte. Amélioration du changement de langue, du sens de lecture et de l’affichage du crédit des voix clonées.'],
    'es': ['DISEÑADO PARA MAC\nLee en ventanas de escritorio con barra lateral, atajos de teclado, importación de archivos al arrastrarlos y compartir con CastReader. Usa tu cuenta de CastReader y tu suscripción Pro actuales.', 'La interfaz y la lectura en Mac ahora admiten 28 idiomas. La lista de voces sigue el idioma de la app y la selección durante la reproducción sigue el idioma del texto. Mejoras en el cambio de idioma, la dirección de lectura y la visualización del saldo de voces clonadas.'],
    'pt-BR': ['FEITO PARA MAC\nLeia em janelas com barra lateral, atalhos de teclado, importação de arquivos por arrastar e soltar e compartilhamento com o CastReader. Use sua conta CastReader e assinatura Pro atuais.', 'A interface e a leitura no Mac agora oferecem 28 idiomas. A lista de vozes segue o idioma do app, e a seleção durante a reprodução segue o idioma do texto. Melhorias na troca de idioma, direção de leitura e exibição do saldo de vozes clonadas.'],
    'it': ['PENSATO PER MAC\nLeggi in finestre con barra laterale, scorciatoie da tastiera, importazione tramite trascinamento e condivisione con CastReader. Usa il tuo account CastReader e abbonamento Pro attuali.', 'L’interfaccia e la lettura su Mac ora supportano 28 lingue. L’elenco delle voci segue la lingua dell’app, mentre la scelta durante la riproduzione segue la lingua del testo. Migliorati il cambio lingua, la direzione di lettura e la visualizzazione del credito delle voci clonate.'],
    'hi': ['MAC के लिए बनाया गया\nसाइडबार, कीबोर्ड शॉर्टकट, फ़ाइलों को खींचकर इंपोर्ट करने और CastReader में शेयर करने की सुविधा वाले डेस्कटॉप विंडो में पढ़ें। अपने मौजूदा CastReader खाते और Pro सदस्यता का उपयोग करें।', 'Mac का इंटरफ़ेस और पढ़कर सुनाना अब 28 भाषाओं में उपलब्ध है। आवाज़ों की सूची ऐप की भाषा के अनुसार और प्लेबैक में आवाज़ का चयन पढ़े जा रहे पाठ की भाषा के अनुसार होता है। भाषा बदलने, पढ़ने की दिशा और क्लोन आवाज़ों का शेष कोटा दिखाने में सुधार किया गया है।'],
    'nl': ['GEMAAKT VOOR MAC\nLees in vensters met een zijbalk, sneltoetsen, bestanden importeren via slepen en neerzetten, en delen met CastReader. Gebruik je bestaande CastReader-account en Pro-lidmaatschap.', 'De interface en het voorlezen op Mac ondersteunen nu 28 talen. Stemlijsten volgen de app-taal; de stemkeuze tijdens het afspelen volgt de taal van de tekst. Verbeterde taalwisseling, leesrichting en saldovermelding voor gekloonde stemmen.'],
    'ko': ['MAC을 위한 앱\n사이드바, 키보드 단축키, 파일 드래그 앤 드롭 가져오기, CastReader로 공유를 지원하는 데스크탑 창에서 읽으세요. 기존 CastReader 계정과 Pro 멤버십을 그대로 사용할 수 있습니다.', 'Mac 화면과 읽어주기가 이제 28개 언어를 지원합니다. 음성 목록은 앱 언어를 따르고, 재생 중 음성 선택은 읽고 있는 언어를 따릅니다. 언어 전환, 읽기 방향, 복제 음성 잔여 할당량 표시를 개선했습니다.'],
    'ar': ['مصمم لـ MAC\nاقرأ في نوافذ سطح المكتب مع شريط جانبي واختصارات لوحة المفاتيح واستيراد الملفات بالسحب والإفلات والمشاركة إلى CastReader. استخدم حساب CastReader وعضوية Pro الحاليين.', 'تدعم واجهة Mac والقراءة الآن 28 لغة. تتبع قوائم الأصوات لغة التطبيق، ويتبع اختيار الصوت أثناء التشغيل لغة النص المقروء. تحسين تبديل اللغة واتجاه القراءة وعرض رصيد الأصوات المستنسخة.'],
    'ru': ['СОЗДАНО ДЛЯ MAC\nЧитайте в окнах с боковой панелью, сочетаниями клавиш, импортом файлов перетаскиванием и отправкой в CastReader через меню «Поделиться». Используйте существующий аккаунт CastReader и подписку Pro.', 'Интерфейс и чтение на Mac теперь поддерживают 28 языков. Список голосов следует языку приложения, а выбор голоса при воспроизведении — языку текста. Улучшены переключение языка, направление чтения и отображение остатка минут клонированных голосов.'],
    'pl': ['STWORZONY DLA MACA\nCzytaj w oknach z paskiem bocznym, skrótami klawiaturowymi, importowaniem plików przez przeciąganie i udostępnianiem do CastReader. Korzystaj z obecnego konta CastReader i subskrypcji Pro.', 'Interfejs i czytanie na Macu obsługują teraz 28 języków. Lista głosów odpowiada językowi aplikacji, a wybór głosu podczas odtwarzania — językowi tekstu. Ulepszono zmianę języka, kierunek czytania i wyświetlanie salda głosów klonowanych.'],
    'sv': ['SKAPAD FÖR MAC\nLäs i skrivbordsfönster med sidofält, kortkommandon, filimport via dra och släpp och delning till CastReader. Använd ditt befintliga CastReader-konto och Pro-medlemskap.', 'Gränssnittet och uppläsningen på Mac stöder nu 28 språk. Röstlistorna följer appens språk och röstval under uppspelning följer textens språk. Förbättrade språkbyten, läsriktning och saldovisning för klonade röster.'],
    'da': ['SKABT TIL MAC\nLæs i skrivebordsvinduer med indholdsoversigt, tastaturgenveje, filimport med træk og slip samt deling til CastReader. Brug din eksisterende CastReader-konto og dit Pro-medlemskab.', 'Grænsefladen og oplæsningen på Mac understøtter nu 28 sprog. Stemmelister følger appens sprog, og stemmevalg under afspilning følger tekstens sprog. Forbedret sprogskift, læseretning og visning af saldo for klonede stemmer.'],
    'nb': ['LAGET FOR MAC\nLes i skrivebordsvinduer med sidepanel, tastatursnarveier, filimport med dra og slipp og deling til CastReader. Bruk din eksisterende CastReader-konto og ditt Pro-medlemskap.', 'Grensesnitt og opplesning på Mac støtter nå 28 språk. Stemmelister følger appens språk, og stemmevalg under avspilling følger tekstens språk. Forbedret språkbytte, leseretning og saldovisning for klonede stemmer.'],
    'fi': ['SUUNNITELTU MACILLE\nLue työpöytäikkunoissa, joissa on sivupalkki, näppäinoikotiet, tiedostojen tuonti vetämällä ja pudottamalla sekä jakaminen CastReaderiin. Käytä nykyistä CastReader-tiliäsi ja Pro-jäsenyyttäsi.', 'Macin käyttöliittymä ja ääneen lukeminen tukevat nyt 28 kieltä. Ääniluettelo seuraa sovelluksen kieltä, ja toiston aikainen äänivalinta seuraa tekstin kieltä. Parannuksia kielenvaihtoon, lukusuuntaan ja kloonattujen äänten saldon näyttöön.'],
    'cs': ['VYTVOŘENO PRO MAC\nČtěte v oknech s bočním panelem, klávesovými zkratkami, importem souborů přetažením a sdílením do CastReaderu. Používejte svůj stávající účet CastReader a členství Pro.', 'Rozhraní a předčítání na Macu nyní podporují 28 jazyků. Seznam hlasů se řídí jazykem aplikace a výběr hlasu při přehrávání jazykem textu. Vylepšeno přepínání jazyků, směr čtení a zobrazení zůstatku klonovaných hlasů.'],
    'el': ['ΣΧΕΔΙΑΣΜΕΝΟ ΓΙΑ MAC\nΔιαβάστε σε παράθυρα με πλαϊνή στήλη, συντομεύσεις πληκτρολογίου, εισαγωγή αρχείων με μεταφορά και απόθεση και κοινοποίηση στο CastReader. Χρησιμοποιήστε τον υπάρχοντα λογαριασμό CastReader και τη συνδρομή Pro.', 'Το περιβάλλον και η ανάγνωση στο Mac υποστηρίζουν πλέον 28 γλώσσες. Οι λίστες φωνών ακολουθούν τη γλώσσα της εφαρμογής και η επιλογή φωνής κατά την αναπαραγωγή τη γλώσσα του κειμένου. Βελτιώθηκαν η αλλαγή γλώσσας, η κατεύθυνση ανάγνωσης και η προβολή υπολοίπου κλωνοποιημένων φωνών.'],
    'hu': ['MACRE TERVEZVE\nOlvasson asztali ablakokban oldalsávval, billentyűparancsokkal, fájlok behúzásával és a CastReaderbe történő megosztással. Használja meglévő CastReader-fiókját és Pro-tagságát.', 'A Mac felülete és felolvasása mostantól 28 nyelvet támogat. A hanglista az alkalmazás nyelvét, a lejátszás közbeni hangválasztás a szöveg nyelvét követi. Javult a nyelvváltás, az olvasási irány és a klónozott hangok egyenlegének megjelenítése.'],
    'fil': ['GINAWA PARA SA MAC\nMagbasa sa mga desktop window na may sidebar, keyboard shortcut, pag-import ng file sa pag-drag at drop, at pagbabahagi sa CastReader. Gamitin ang dati mong CastReader account at Pro membership.', 'Sinusuportahan na ng interface at pagbasa sa Mac ang 28 wika. Ang listahan ng mga boses ay sumusunod sa wika ng app, at ang pagpili ng boses habang nagpe-play ay sumusunod sa wika ng binabasa. Pinahusay ang pagpapalit ng wika, direksyon ng pagbasa, at pagpapakita ng balanse ng mga cloned voice.'],
    'he': ['מותאם ל-MAC\nקראו בחלונות שולחן עבודה עם סרגל צד, קיצורי מקלדת, ייבוא קבצים בגרירה ושחרור ושיתוף אל CastReader. השתמשו בחשבון CastReader ובמינוי Pro הקיימים שלכם.', 'הממשק וההקראה ב-Mac תומכים כעת ב-28 שפות. רשימות הקולות מותאמות לשפת היישום, ובחירת קול בזמן הנגינה מותאמת לשפת הטקסט. שופרו החלפת השפה, כיוון הקריאה והצגת יתרת הקולות המשוכפלים.'],
    'id': ['DIBUAT UNTUK MAC\nBaca di jendela desktop dengan bar samping, pintasan keyboard, impor file dengan seret dan lepas, serta berbagi ke CastReader. Gunakan akun CastReader dan keanggotaan Pro Anda yang sudah ada.', 'Antarmuka dan pembacaan di Mac kini mendukung 28 bahasa. Daftar suara mengikuti bahasa aplikasi, dan pilihan suara saat pemutaran mengikuti bahasa teks. Peningkatan pergantian bahasa, arah membaca, dan tampilan saldo suara kloning.'],
    'ms': ['DIBINA UNTUK MAC\nBaca dalam tetingkap desktop dengan bar sisi, pintasan papan kekunci, import fail melalui seret dan lepas serta perkongsian ke CastReader. Gunakan akaun CastReader dan keahlian Pro sedia ada anda.', 'Antara muka dan bacaan pada Mac kini menyokong 28 bahasa. Senarai suara mengikut bahasa aplikasi, dan pilihan suara semasa main balik mengikut bahasa teks. Penukaran bahasa, arah bacaan dan paparan baki suara klon telah ditambah baik.'],
    'ro': ['CREAT PENTRU MAC\nCitește în ferestre cu bară laterală, scurtături de tastatură, import de fișiere prin tragere și plasare și partajare către CastReader. Folosește contul CastReader și abonamentul Pro existente.', 'Interfața și lectura pe Mac acceptă acum 28 de limbi. Listele de voci urmează limba aplicației, iar alegerea vocii în timpul redării urmează limba textului. Îmbunătățiri la schimbarea limbii, direcția de lectură și afișarea soldului vocilor clonate.'],
    'tr': ['MAC İÇİN TASARLANDI\nKenar çubuğu, klavye kısayolları, sürükleyip bırakarak dosya içe aktarma ve CastReader’a paylaşma özellikleriyle masaüstü pencerelerinde okuyun. Mevcut CastReader hesabınızı ve Pro üyeliğinizi kullanın.', 'Mac arayüzü ve sesli okuma artık 28 dili destekliyor. Ses listeleri uygulama dilini, oynatma sırasında ses seçimi ise okunan metnin dilini izler. Dil değiştirme, okuma yönü ve klonlanmış ses bakiyesi gösterimi iyileştirildi.'],
    'vi': ['ĐƯỢC THIẾT KẾ CHO MAC\nĐọc trong cửa sổ máy tính với thanh bên, phím tắt, nhập tệp bằng kéo và thả, cùng tính năng chia sẻ đến CastReader. Sử dụng tài khoản CastReader và gói Pro hiện có của bạn.', 'Giao diện và đọc thành tiếng trên Mac nay hỗ trợ 28 ngôn ngữ. Danh sách giọng theo ngôn ngữ ứng dụng, còn lựa chọn giọng khi phát theo ngôn ngữ văn bản. Cải thiện chuyển ngôn ngữ, hướng đọc và hiển thị hạn mức giọng nhân bản.'],
}

source = json.loads((IOS / 'metadata.json').read_text())
ios_copy = json.loads((IOS / 'ios-copy.json').read_text())
assert set(source) == set(COPY)
result = {}
for language, original in source.items():
    entry = dict(original)
    platform, whats_new = COPY[language]
    old_platform = ios_copy[language]['platform']
    assert entry['description'].startswith(old_platform + '\n\n')
    entry['description'] = platform + entry['description'][len(old_platform):]
    entry['whatsNew'] = whats_new
    entry['macCaptions'] = entry.pop('ipadCaptions')
    entry.pop('phoneCaptions')
    assert len(entry['description']) <= 4000, language
    assert all(x not in entry['description'] for x in ['iPhone', 'iPad', 'Android', 'Safari']), language
    result[language] = entry
(HERE / 'metadata.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
asc = {x['ascLocale']: x for x in result.values() if x['ascLocale']}
asc['es-MX'] = dict(result['es'], ascLocale='es-MX')
# Keep the existing Traditional Chinese regional entry with matching Mac copy.
baseline = json.loads((ROOT / 'reports/mac-28-languages-20261011/asc-baseline.json').read_text())
old_hant = next(x['data']['attributes'] for x in baseline['localizations'] if x['data']['attributes']['locale'] == 'zh-Hant')
asc['zh-Hant'] = dict(result['zh-Hans'], ascLocale='zh-Hant',
    description='''為 Mac 打造
透過桌面視窗、側邊欄、鍵盤快捷鍵、拖放檔案及分享到 CastReader 進行閱讀。沿用現有 CastReader 帳號與 Pro 會員。

CastReader 把文字變成「能聽，也能懂」的內容。

朗讀 —— 讓注意力跟上聲音

照片、網頁、PDF、EPUB 和純文字都能轉換成自然語音。同步反白搭配自動捲動，讓眼睛與耳朵停留在同一句話上。

AI 解讀 —— 不只讀，更讀懂

CastReader 產生清楚的講解並朗讀，同時在原文上逐筆顯示手寫風格標註：反白重點、圈出關鍵詞、標示步驟。邊聽講解邊看原文，更容易理解複雜資料。

匯入自己的內容

- 相機或照片：在裝置上辨識文字
- 網頁：輸入網址即可開始朗讀或解讀
- 檔案：支援 PDF、EPUB、TXT、DOCX 與圖片
- 貼上：複製文字即可立即收聽
- Kindle：連結 Kindle 書庫並繼續閱讀
- 聆聽 YouTube：分享或貼上公開影片連結，朗讀公開字幕並同步反白

「聆聽 YouTube」僅支援具備可存取公開字幕的公開影片。需要登入、年齡驗證、會員資格、地區權限或私人存取權限的影片無法讀取。CastReader 不播放、下載或保留 YouTube 影音串流；朗讀語音僅由字幕文字產生。CastReader 不隸屬於 YouTube，也未獲得 YouTube 認可。

適合誰

- 想用聽的方式讀完文章、資料和電子書的人
- 需要同步視覺引導的語言學習者
- 需要處理論文、報告、教材和合約的學生與專業人士
- 需要護眼或無障礙閱讀輔助的人

28 種語言

支援英語、中文、日語、西班牙語、法語、德語、巴西葡萄牙語、義大利語、印地語、荷蘭語、韓語、阿拉伯語、俄語、波蘭語、瑞典語、丹麥語、挪威語、芬蘭語、捷克語、希臘語、匈牙利語、菲律賓語、希伯來語、印尼語、馬來語、羅馬尼亞語、土耳其語和越南語。介面也已適配這 28 種語言。可選音色與音色複製的支援情況因語言而異。

免費使用與 CastReader Pro

每天都可免費使用 CastReader。Pro 提供按月或按年訂閱，可使用標準音色無限朗讀、無限 AI 解讀、進階音色，以及最高 3 倍語速。複製音色需要 Pro，並使用獨立額度：每個按月額度週期含 120 分鐘。還可購買 120 分鐘加時包，增加複製音色朗讀時間；加時包不延長 Pro 效期。當地價格、計費週期與續訂條款以購買前 App Store 顯示為準。

音色和功能的可用範圍依地區而異。

支援深色模式與背景播放。照片文字使用 Apple 裝置端 OCR 辨識，準確度依語言和圖片品質而異；照片不會為了辨識文字而上傳。本機閱讀記錄保留在裝置上，已連結服務依各自政策保存其帳號與閱讀資料。

EULA: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/''',
    whatsNew='Mac 介面與朗讀現已支援 28 種語言。音色清單跟隨應用程式語言，播放中更換音色則跟隨正在閱讀的語言。改進語言切換、閱讀方向與複製音色額度顯示。')
# Preserve existing Mac links, keywords and promotional text. This campaign
# intentionally changes descriptions, release notes and screenshots only.
for old in baseline['localizations']:
    attrs = old['data']['attributes']
    for field in ('keywords', 'promotionalText', 'supportUrl', 'marketingUrl'):
        asc[attrs['locale']][field] = attrs.get(field)
assert len(asc) == 29
(HERE / 'asc-metadata.json').write_text(json.dumps(asc, ensure_ascii=False, indent=2) + '\n')
lines = ['# CastReader for Mac 1.2.48 — 28-language store copy', '']
for language, entry in result.items():
    lines += ['## ' + language, '', entry['description'], '', '### What’s New', '', entry['whatsNew'], '', '### Five screenshots', '']
    lines += [f'{i}. {caption}' for i, caption in enumerate(entry['macCaptions'], 1)]
    lines.append('')
(HERE / 'metadata.md').write_text('\n'.join(lines))
print(json.dumps({'languages': len(result), 'ascLocales': len(asc), 'localOnly': ['fil'],
                  'maxDescriptionLength': max(len(x['description']) for x in result.values())}))
