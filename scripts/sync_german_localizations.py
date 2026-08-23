#!/usr/bin/env python3
"""Populate the German String Catalog entries from the reviewed product glossary."""

from __future__ import annotations

import json
from copy import deepcopy
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

GERMAN = dict(
    line.split("\t", 1)
    for line in r"""
%.1f seconds · 3–30 seconds required · up to 4 MB	%.1f Sekunden · 3–30 Sekunden erforderlich · bis zu 4 MB
%lld chapters	%lld Kapitel
%lld words	%lld Wörter
%lld voices	%lld Stimmen
%lld min ago	vor %lld Min.
%lld d ago	vor %lld T.
%lld h ago	vor %lld Std.
%lld languages	%lld Sprachen
Amazon Kindle account	Amazon-Kindle-Konto
Apple Sign In failed	Apple-Anmeldung fehlgeschlagen
Cancel	Abbrechen
Debug only: test whether WebView can keep scrolling after the phone is locked	Nur Debug: Testen, ob WebView nach dem Sperren weiter scrollen kann
English	Englisch
EPUBs, long PDFs, excerpts, or chapters	EPUBs, lange PDFs, Auszüge oder Kapitel
Explaining · block %lld/%lld	Erklärung · Abschnitt %lld/%lld
GitHub docs, API docs, product manuals, and help centers	GitHub-Dokumentation, API-Dokumentation, Produkthandbücher und Hilfe-Center
Google sign-in is not configured (set Constants.GoogleOAuth.clientID)	Google-Anmeldung ist nicht konfiguriert (Constants.GoogleOAuth.clientID festlegen)
Kindle Book	Kindle-Buch
Kindle Library	Kindle-Bibliothek
Unexpected Kindle library response.	Unerwartete Antwort der Kindle-Bibliothek.
Kindle library synced.	Kindle-Bibliothek synchronisiert.
This Kindle book needs to be synced again	Dieses Kindle-Buch muss erneut synchronisiert werden
Kindle Background Scroll Probe	Kindle-Hintergrund-Scrolltest
Your Kindle session has expired. Sign in again and sync your library.	Deine Kindle-Sitzung ist abgelaufen. Melde dich erneut an und synchronisiere deine Bibliothek.
Kindle returned unexpected page data.	Kindle hat unerwartete Seitendaten zurückgegeben.
The Kindle page image could not be decoded.	Das Bild der Kindle-Seite konnte nicht decodiert werden.
Kindle pages are already being prepared.	Kindle-Seiten werden bereits vorbereitet.
The Kindle page is not ready yet	Die Kindle-Seite ist noch nicht bereit
PDF / TXT / Image / EPUB	PDF / TXT / Bild / EPUB
Playback Speed	Wiedergabegeschwindigkeit
Something went wrong	Ein Fehler ist aufgetreten
Today is a pleasant day. I am recording this sample in a clear, natural voice so CastReader can reproduce my voice accurately.	Heute ist ein angenehmer Tag. Ich nehme dieses Beispiel mit klarer, natürlicher Stimme auf, damit CastReader meine Stimme genau wiedergeben kann.
Try Again	Erneut versuchen
Untitled	Ohne Titel
Previous Page	Vorherige Seite
Uploading…	Wird hochgeladen …
Upload Image	Bild hochladen
Upload File	Datei hochladen
Next Page	Nächste Seite
Ready on next Kindle page.	Nächste Kindle-Seite ist bereit.
Next voice available at: %@	Nächste Stimme verfügbar um: %@
and	und
Chinese	Chinesisch
Recorded in Chinese	Auf Chinesisch aufgenommen
Title	Titel
Your library was synced, but Kindle could not open this book. Try again or return to the library.	Deine Bibliothek wurde synchronisiert, aber Kindle konnte dieses Buch nicht öffnen. Versuche es erneut oder kehre zur Bibliothek zurück.
Books / Long-form	Bücher / Lange Texte
Stored on this device only, never uploaded	Nur auf diesem Gerät gespeichert, niemals hochgeladen
Today is a pleasant day. I am recording a clear, natural sample so CastReader can reproduce my voice accurately.	Heute ist ein angenehmer Tag. Ich nehme ein klares, natürliches Beispiel auf, damit CastReader meine Stimme genau wiedergeben kann.
%1$d min Read Aloud · %2$d Explains left today	Heute noch %1$d Min. Vorlesen · %2$d Erklärungen
%1$lld min Read Aloud · %2$lld Explains left today	Heute noch %1$lld Min. Vorlesen · %2$lld Erklärungen
Choose from Library	Aus Mediathek wählen
Author	Autor
You're a Pro member	Du bist Pro-Mitglied
Continue with Google	Mit Google fortfahren
Repair and Open	Reparieren und öffnen
Stop Recording	Aufnahme stoppen
Stop Preview	Vorschau stoppen
Import content first, or choose an explanation scenario	Importiere zuerst Inhalte oder wähle ein Erklärungsszenario
Free	Kostenlos
Free plan max speed is 2.0x	Im kostenlosen Tarif maximal 2,0×
All	Alle
All Premium Voices	Alle Premium-Stimmen
Focus on definitions, concepts, examples, and common mistakes	Definitionen, Konzepte, Beispiele und häufige Fehler hervorheben
Focus on rights, obligations, amounts, deadlines, and risk clauses	Rechte, Pflichten, Beträge, Fristen und Risikoklauseln hervorheben
Focus on core ideas, concepts, turning points, and memorable lines	Kernaussagen, Konzepte, Wendepunkte und prägnante Sätze hervorheben
Focus on core ideas, concept relationships, and turning points	Kernaussagen, Begriffsbeziehungen und Wendepunkte hervorheben
Focus on steps, parameters, limits, and warnings	Schritte, Parameter, Grenzen und Warnungen hervorheben
Focus on research questions, methods, experiments, and contributions	Forschungsfragen, Methoden, Experimente und Beiträge hervorheben
Focus on the research question, method, conclusions, and contribution	Forschungsfrage, Methode, Schlussfolgerungen und Beitrag hervorheben
Focus on conclusions, key data, assumptions, and risks	Schlussfolgerungen, Kerndaten, Annahmen und Risiken hervorheben
Focus on conclusions, data, risks, and assumptions	Schlussfolgerungen, Daten, Risiken und Annahmen hervorheben
Key steps · Warnings · Specs	Wichtige Schritte · Warnungen · Spezifikationen
Close	Schließen
Content	Inhalt
Content too short to explain. Try Read Aloud.	Inhalt zu kurz für eine Erklärung. Versuche Vorlesen.
This content is too short or is not supported for explanation. Try again later.	Dieser Inhalt ist zu kurz oder wird für Erklärungen nicht unterstützt. Versuche es später erneut.
Recent	Zuletzt
Up to 3× Speed	Bis zu 3× Geschwindigkeit
Just now	Gerade eben
Create Voice	Stimme erstellen
Create New Voice	Neue Stimme erstellen
Content Inbox	Inhalts-Eingang
This content could not be opened. Please try again.	Dieser Inhalt konnte nicht geöffnet werden. Bitte versuche es erneut.
Your inbox is empty	Dein Eingang ist leer
Share webpages, text, documents, or images from other apps to CastReader. They will be saved here.	Teile Webseiten, Text, Dokumente oder Bilder aus anderen Apps mit CastReader. Sie werden hier gespeichert.
Delete	Löschen
You will no longer be able to use this voice after deleting it.	Nach dem Löschen kannst du diese Stimme nicht mehr verwenden.
Delete all local history in your Library. History is stored only on this device and is never uploaded or synced to the cloud.	Den gesamten lokalen Verlauf in der Bibliothek löschen. Der Verlauf wird nur auf diesem Gerät gespeichert und weder hochgeladen noch mit der Cloud synchronisiert.
Delete This Voice?	Diese Stimme löschen?
Refresh	Aktualisieren
Refresh Kindle library	Kindle-Bibliothek aktualisieren
Refresh Kindle book	Kindle-Buch aktualisieren
This refresh syncs your library and updates this book's entry without clearing playback settings.	Dabei wird deine Bibliothek synchronisiert und der Bucheintrag aktualisiert, ohne die Wiedergabeeinstellungen zu löschen.
Clipboard Text	Text aus Zwischenablage
There's a link in your clipboard	In deiner Zwischenablage befindet sich ein Link
There's an image in your clipboard	In deiner Zwischenablage befindet sich ein Bild
There's text in your clipboard	In deiner Zwischenablage befindet sich Text
Load More	Mehr laden
Loading subscriptions…	Abonnements werden geladen …
Upgrade Pro	Auf Pro upgraden
Upgrade to CastReader Pro	Auf CastReader Pro upgraden
Upgrade to Pro	Auf Pro upgraden
Upgrade to create a voice and choose it for Chinese or English.	Upgrade, um eine Stimme zu erstellen und sie für Chinesisch oder Englisch auszuwählen.
History is kept on this device only — never uploaded or synced to the cloud	Der Verlauf bleibt nur auf diesem Gerät – er wird nie hochgeladen oder mit der Cloud synchronisiert
Remove from Favorites	Aus Favoriten entfernen
Accent	Akzent
Contracts / Terms	Verträge / Bedingungen
Contracts, terms, agreements, quotes, and SLAs	Verträge, Bedingungen, Vereinbarungen, Angebote und SLAs
Sync	Synchronisieren
Sync Kindle library	Kindle-Bibliothek synchronisieren
Sync needs attention.	Synchronisierung erfordert Aufmerksamkeit.
Image	Bild
Use Camera, Upload File, Enter URL, or Enter Text on Home — processed content shows up here	Verwende auf der Startseite Kamera, Datei hochladen, URL eingeben oder Text eingeben – verarbeitete Inhalte erscheinen hier
Voice Cloning	Stimmenklonen
Voice cloning is available to Pro members only.	Stimmenklonen ist nur für Pro-Mitglieder verfügbar.
Voice cloning sign-in is not ready yet. Please try again later.	Die Anmeldung zum Stimmenklonen ist noch nicht bereit. Bitte versuche es später erneut.
Voice cloning request failed.	Anfrage zum Stimmenklonen fehlgeschlagen.
Voice cloning returned invalid data.	Das Stimmenklonen hat ungültige Daten zurückgegeben.
Voice cloning requires Pro	Stimmenklonen erfordert Pro
Voice cloning requires a secure account session.	Stimmenklonen erfordert eine sichere Kontositzung.
The voice service is temporarily unavailable. Please try again later.	Der Stimmendienst ist vorübergehend nicht verfügbar. Bitte versuche es später erneut.
The voice service is busy. Please try again.	Der Stimmendienst ist ausgelastet. Bitte versuche es erneut.
Multilingual	Mehrsprachig
Female	Weiblich
OK	OK
If you see your Kindle library, tap Sync.	Wenn deine Kindle-Bibliothek angezeigt wird, tippe auf Synchronisieren.
Done	Fertig
Import	Importieren
Import Method	Importmethode
This will delete all local history in your Library. This action cannot be undone.	Dadurch wird der gesamte lokale Verlauf in deiner Bibliothek gelöscht. Diese Aktion kann nicht rückgängig gemacht werden.
This will clear the local Kindle shelf cache and the read.amazon.com sign-in state. The Kindle module on Home will return to Connect Kindle, and you will need to sign in and sync again.	Dadurch werden der lokale Kindle-Bibliothekscache und die Anmeldung bei read.amazon.com gelöscht. Das Kindle-Modul auf der Startseite zeigt wieder „Kindle verbinden“ und du musst dich erneut anmelden und synchronisieren.
Not started	Noch nicht begonnen
Google Sign-In is not configured	Google-Anmeldung ist nicht konfiguriert
Try another search or filter.	Versuche eine andere Suche oder einen anderen Filter.
Uploaded. You'll find it in your Library once processing is done	Hochgeladen. Nach der Verarbeitung findest du den Inhalt in deiner Bibliothek
Reading from the current page.	Vorlesen ab der aktuellen Seite.
Stopped on the current page. Tap Play to continue.	Auf der aktuellen Seite gestoppt. Tippe zum Fortfahren auf Wiedergabe.
Created	Erstellt
Reached the end of the current Kindle content.	Das Ende des aktuellen Kindle-Inhalts wurde erreicht.
Sign-in canceled	Anmeldung abgebrochen
Your synced Kindle library	Deine synchronisierte Kindle-Bibliothek
Already purchased on another device? Sign in to restore Pro	Bereits auf einem anderen Gerät gekauft? Anmelden, um Pro wiederherzustellen
%d books synced locally.	%d Bücher lokal synchronisiert.
Ready.	Bereit.
Kindle reading resumed.	Kindle-Vorlesen fortgesetzt.
Pro restored	Pro wiederhergestellt
Purchase restored. This device is unlocked; cross-platform sync is waiting for Apple verification.	Kauf wiederhergestellt. Dieses Gerät ist entsperrt; die plattformübergreifende Synchronisierung wartet auf die Apple-Verifizierung.
Found %d Kindle books...	%d Kindle-Bücher gefunden …
Kindle table of contents detected.	Kindle-Inhaltsverzeichnis erkannt.
Finished · tap Play to read again	Beendet · zum erneuten Vorlesen auf Wiedergabe tippen
Paused	Pausiert
Paused. Tap Play to continue.	Pausiert. Tippe zum Fortfahren auf Wiedergabe.
Paused. Choose where to start reading.	Pausiert. Wähle aus, wo das Vorlesen beginnen soll.
Purchase detected. This device is unlocked; cross-platform sync is waiting for Apple verification.	Kauf erkannt. Dieses Gerät ist entsperrt; die plattformübergreifende Synchronisierung wartet auf die Apple-Verifizierung.
Purchase detected. Log in with your email to sync Pro.	Kauf erkannt. Melde dich mit deiner E-Mail-Adresse an, um Pro zu synchronisieren.
Purchase detected. Log in with your email to enable cross-platform Pro.	Kauf erkannt. Melde dich mit deiner E-Mail-Adresse an, um Pro plattformübergreifend zu aktivieren.
Signed In	Angemeldet
Signed in: %@	Angemeldet: %@
Connected	Verbunden
Unlocked	Entsperrt
Yearly Subscription	Jahresabonnement
All features are unlocked by default during development. Turn this off when testing real purchases or cross-platform entitlements, and run from Xcode so the local StoreKit configuration takes effect.	Während der Entwicklung sind standardmäßig alle Funktionen entsperrt. Deaktiviere dies zum Testen echter Käufe oder plattformübergreifender Berechtigungen und starte über Xcode, damit die lokale StoreKit-Konfiguration wirksam wird.
Start	Starten
Start Recording	Aufnahme starten
Start Explaining	Erklärung starten
Ready on this Kindle page.	Diese Kindle-Seite ist bereit.
No readable text was recognized on this Kindle page.	Auf dieser Kindle-Seite wurde kein vorlesbarer Text erkannt.
Kindle book page open. Return to Kindle Library, then Sync.	Eine Kindle-Buchseite ist geöffnet. Kehre zur Kindle-Bibliothek zurück und synchronisiere.
This is a Kindle book page. Sync from the library shelf.	Dies ist eine Kindle-Buchseite. Synchronisiere über die Bibliothek.
No Kindle books were found on this page yet.	Auf dieser Seite wurden noch keine Kindle-Bücher gefunden.
No Kindle books were found on this page.	Auf dieser Seite wurden keine Kindle-Bücher gefunden.
The recording must be no larger than 4 MB.	Die Aufnahme darf höchstens 4 MB groß sein.
The recording could not be saved completely. Please record it again.	Die Aufnahme konnte nicht vollständig gespeichert werden. Bitte nimm sie erneut auf.
The recording did not pass server validation.	Die Aufnahme hat die Serverprüfung nicht bestanden.
Recording Language	Aufnahmesprache
Quick Import	Schnellimport
Ignore	Ignorieren
Gender	Geschlecht
Restore Purchases	Käufe wiederherstellen
My Voices	Meine Stimmen
My Voice %lld	Meine Stimme %lld
I confirm this is my voice and authorize CastReader to use it to generate speech.	Ich bestätige, dass dies meine Stimme ist, und erlaube CastReader, damit Sprache zu erzeugen.
Open	Öffnen
Open Amazon Kindle and sign in.	Öffne Amazon Kindle und melde dich an.
Open your Kindle library, then tap Sync.	Öffne deine Kindle-Bibliothek und tippe auf Synchronisieren.
Open any position, then tap Play to read aloud.	Öffne eine beliebige Stelle und tippe zum Vorlesen auf Wiedergabe.
Open any location, then choose Read Aloud or Explain.	Öffne eine beliebige Stelle und wähle Vorlesen oder Erklären.
Open a web page to Read Aloud or Explain	Öffne eine Webseite zum Vorlesen oder Erklären
Reports / Research	Berichte / Analysen
Camera / Photos	Kamera / Fotos
Everything you capture, upload, or paste lives here. Stored on this device only.	Alles, was du aufnimmst, hochlädst oder einfügst, erscheint hier. Nur auf diesem Gerät gespeichert.
Capture printed content or a screen	Gedruckte Inhalte oder einen Bildschirm erfassen
Take Photo	Foto aufnehmen
Take a photo or pick from your library to recognize text	Nimm ein Foto auf oder wähle eines aus deiner Mediathek, um Text zu erkennen
Weekly subscription	Wöchentliches Abonnement
Daily subscription	Tägliches Abonnement
Yearly subscription	Jährliches Abonnement
Monthly subscription	Monatliches Abonnement
Sort	Sortieren
Explore	Entdecken
Recommended	Empfohlen
Notice	Hinweis
Search Kindle books	Kindle-Bücher suchen
Search title or URL	Titel oder URL suchen
Search Languages	Sprachen suchen
Search Voices	Stimmen suchen
Play	Wiedergabe
Favorites	Favoriten
Textbooks / Study	Lehrbücher / Lernen
Textbooks, slides, study materials, and exercises	Lehrbücher, Folien, Lernmaterialien und Übungen
Data	Daten
Library	Bibliothek
Text	Text
No content to read aloud	Kein Inhalt zum Vorlesen
Invalid explanation service address	Ungültige Adresse des Erklärungsdienstes
Unable to Start Recording	Aufnahme konnte nicht gestartet werden
Could not attach highlights to the Kindle page: %@	Hervorhebungen konnten nicht an die Kindle-Seite angefügt werden: %@
Could not capture the Kindle page: %@	Kindle-Seite konnte nicht erfasst werden: %@
Could not parse the Kindle page image	Das Bild der Kindle-Seite konnte nicht verarbeitet werden
Couldn't parse sign-in info	Anmeldeinformationen konnten nicht verarbeitet werden
Couldn't parse this EPUB.	Dieses EPUB konnte nicht verarbeitet werden.
Could not read the current Kindle page	Die aktuelle Kindle-Seite konnte nicht gelesen werden
Unable to read image	Bild kann nicht gelesen werden
Could not read file: %@	Datei konnte nicht gelesen werden: %@
Couldn't read the text file	Die Textdatei konnte nicht gelesen werden
Couldn't read this PDF (it may be a scan with no text layer; try Camera instead)	Dieses PDF konnte nicht gelesen werden (möglicherweise ein Scan ohne Textebene; versuche stattdessen die Kamera)
Couldn't read this file	Diese Datei konnte nicht gelesen werden
Unlimited Read Aloud	Unbegrenzt vorlesen
Unlimited Explanations	Unbegrenzte Erklärungen
Yesterday	Gestern
No recently used voices	Keine kürzlich verwendeten Stimmen
No favorite voices yet	Noch keine bevorzugten Stimmen
No table of contents was found for this book yet.	Für dieses Buch wurde noch kein Inhaltsverzeichnis gefunden.
No Kindle table of contents detected yet.	Noch kein Kindle-Inhaltsverzeichnis erkannt.
No table of contents is cached for this book yet. Open it once in portrait first.	Für dieses Buch ist noch kein Inhaltsverzeichnis zwischengespeichert. Öffne es zuerst einmal im Hochformat.
Monthly Subscription	Monatsabonnement
Terms of Service	Nutzungsbedingungen
Read Aloud	Vorlesen
Reading Aloud	Wird vorgelesen
Reading Language	Vorlesesprache
Could not find the Kindle page image: %@	Das Bild der Kindle-Seite wurde nicht gefunden: %@
No records matching “%@”	Keine Einträge für „%@“
No purchases to restore	Keine Käufe zum Wiederherstellen
Unknown author	Unbekannter Autor
This book could not be found in your Kindle library. Please sync the library manually.	Dieses Buch wurde in deiner Kindle-Bibliothek nicht gefunden. Bitte synchronisiere die Bibliothek manuell.
No text recognized	Kein Text erkannt
Unlocked on this device. Cross-platform sync is pending.	Auf diesem Gerät entsperrt. Die plattformübergreifende Synchronisierung steht noch aus.
This device is unlocked; log in with your email to sync Pro across platforms.	Dieses Gerät ist entsperrt. Melde dich mit deiner E-Mail-Adresse an, um Pro plattformübergreifend zu synchronisieren.
This device is unlocked; cross-platform sync is waiting for Apple verification.	Dieses Gerät ist entsperrt; die plattformübergreifende Synchronisierung wartet auf die Apple-Verifizierung.
Rights · Amounts & terms · Risk clauses	Rechte · Beträge und Fristen · Risikoklauseln
View Pro	Pro anzeigen
View all	Alle anzeigen
Standard	Standard
Title (optional)	Titel (optional)
Conclusions · Key data · Risks	Schlussfolgerungen · Kerndaten · Risiken
Key ideas · Quotes · Concepts · Turns	Kernaussagen · Zitate · Konzepte · Wendepunkte
Simulate Pro Unlock	Pro-Entsperrung simulieren
""".strip().splitlines()
)


GERMAN.update(
    dict(
        line.split("\t", 1)
        for line in r"""
Opening the book from your Kindle library…	Buch wird aus deiner Kindle-Bibliothek geöffnet …
Continuing from the current Kindle page...	Ab der aktuellen Kindle-Seite wird fortgefahren …
Repairing…	Wird repariert …
Preparing Kindle pages...	Kindle-Seiten werden vorbereitet …
Preparing…	Wird vorbereitet …
Preparing the next section...	Der nächste Abschnitt wird vorbereitet …
Preparing current Kindle page...	Aktuelle Kindle-Seite wird vorbereitet …
Preparing block %1$lld/%2$lld…	Abschnitt %1$lld/%2$lld wird vorbereitet …
Switching Kindle page...	Kindle-Seite wird gewechselt …
Switching voice: %1$@ → %2$@	Stimme wird gewechselt: %1$@ → %2$@
Creating Voice	Stimme wird erstellt
Refreshing current Kindle page...	Aktuelle Kindle-Seite wird aktualisiert …
Loading the next Kindle page for explanation…	Nächste Kindle-Seite für die Erklärung wird geladen …
Loading next Kindle page...	Nächste Kindle-Seite wird geladen …
Loading table of contents...	Inhaltsverzeichnis wird geladen …
Syncing your Kindle library…	Kindle-Bibliothek wird synchronisiert …
Syncing Pro status...	Pro-Status wird synchronisiert …
Aligning Kindle page...	Kindle-Seite wird ausgerichtet …
Applying the Kindle reading position…	Kindle-Leseposition wird angewendet …
Resuming Kindle reading…	Kindle-Vorlesen wird fortgesetzt …
Opening your Kindle library…	Kindle-Bibliothek wird geöffnet …
Opening next Kindle page...	Nächste Kindle-Seite wird geöffnet …
Scanning Kindle library...	Kindle-Bibliothek wird durchsucht …
Capturing page %d...	Seite %d wird erfasst …
Detecting Kindle table of contents...	Kindle-Inhaltsverzeichnis wird erkannt …
Updating table of contents...	Inhaltsverzeichnis wird aktualisiert …
Waiting for your Kindle library…	Auf deine Kindle-Bibliothek wird gewartet …
Waiting for the Kindle page to stabilize...	Es wird gewartet, bis die Kindle-Seite stabil ist …
Turning to the next Kindle page for explanation…	Für die Erklärung wird zur nächsten Kindle-Seite geblättert …
Turning to the next Kindle page...	Es wird zur nächsten Kindle-Seite geblättert …
Reading the current Kindle page...	Aktuelle Kindle-Seite wird gelesen …
Jumping to chapter...	Zum Kapitel wird gesprungen …
Adapting to the screen orientation...	An die Bildschirmausrichtung wird angepasst …
Syncing the Kindle book again…	Kindle-Buch wird erneut synchronisiert …
Reopening the book…	Buch wird erneut geöffnet …
Prefetching page %d...	Seite %d wird vorgeladen …
This voice requires CastReader Pro.	Diese Stimme erfordert CastReader Pro.
You can create only one voice every 24 hours.	Du kannst nur alle 24 Stunden eine Stimme erstellen.
Voice choices are saved per language, and available languages update automatically from the cloud catalog.	Die Stimmenauswahl wird je Sprache gespeichert; verfügbare Sprachen werden automatisch aus dem Cloud-Katalog aktualisiert.
No matching books	Keine passenden Bücher
No matching voices	Keine passenden Stimmen
No Kindle page image was found. Open a book page and try again.	Kein Bild einer Kindle-Seite gefunden. Öffne eine Buchseite und versuche es erneut.
Browse All Voices	Alle Stimmen durchsuchen
Deep	Tief
Clear All	Alle löschen
Clear All History	Gesamten Verlauf löschen
Clear all history?	Gesamten Verlauf löschen?
Photo Source	Fotoquelle
Use for Chinese	Für Chinesisch verwenden
Use for English	Für Englisch verwenden
Male	Männlich
Sign In	Anmelden
Sign In / Sign Up	Anmelden / Registrieren
Sign In to CastReader	Bei CastReader anmelden
Sign in to sync Pro and usage across devices	Anmelden, um Pro und Nutzung geräteübergreifend zu synchronisieren
Sign in to create a voice	Zum Erstellen einer Stimme anmelden
Sign in to sync your shelf	Anmelden, um deine Bibliothek zu synchronisieren
Sign in, then tap Sync.	Melde dich an und tippe dann auf Synchronisieren.
Invalid sign-in callback	Ungültiger Anmelderückruf
Sign-in failed: %@	Anmeldung fehlgeschlagen: %@
Log in with email to sync Pro	Mit E-Mail-Adresse anmelden, um Pro zu synchronisieren
Log in with email to buy Pro	Mit E-Mail-Adresse anmelden, um Pro zu kaufen
Table of Contents	Inhaltsverzeichnis
Concepts · Definitions · Exam points	Konzepte · Definitionen · Prüfungswissen
Research reports, industry reports, and data analysis articles	Forschungsberichte, Branchenberichte und Datenanalysen
Questions · Methods · Findings · Contributions	Fragen · Methoden · Ergebnisse · Beiträge
Manage Voices by Language	Stimmen nach Sprache verwalten
Manage Subscription	Abonnement verwalten
Paste or type some text	Text einfügen oder eingeben
Paste or type a passage	Textabschnitt einfügen oder eingeben
Paste Text	Text einfügen
Composing explanation…	Erklärung wird erstellt …
Connect Kindle	Kindle verbinden
Continue	Fortfahren
By continuing, you agree to our	Wenn du fortfährst, stimmst du Folgendem zu:
Continue Listening	Weiterhören
Continuing explanation…	Erklärung wird fortgesetzt …
URL	URL
Invalid URL	Ungültige URL
Web	Web
Web pages, docs, and article links	Webseiten, Dokumentationen und Artikellinks
US	USA
Listen More. Understand More.	Mehr hören. Mehr verstehen.
Auto-highlight · Annotate	Automatisch hervorheben · Kommentieren
Auto-play	Automatische Wiedergabe
Auto-scroll	Automatisches Scrollen
Auto-renewing subscription. It renews 24 hours before the current period ends unless canceled in App Store settings.	Automatisch verlängerndes Abonnement. Es verlängert sich 24 Stunden vor Ablauf des aktuellen Zeitraums, sofern es nicht in den App-Store-Einstellungen gekündigt wird.
UK	Großbritannien
Recorded in English	Auf Englisch aufgenommen
Read Aloud or Explain?	Vorlesen oder erklären?
Unlink	Verknüpfung lösen
Unbind Kindle	Kindle trennen
Unbind Kindle?	Kindle trennen?
Unlinking only clears CastReader’s Kindle sign-in state and library cache on this device. It does not affect your Amazon account or Kindle books.	Beim Trennen werden nur die Kindle-Anmeldung und der Bibliothekscache von CastReader auf diesem Gerät gelöscht. Dein Amazon-Konto und deine Kindle-Bücher bleiben unberührt.
Explain	Erklären
Explaining	Wird erklärt
Scenarios	Szenarien
Explanation failed	Erklärung fehlgeschlagen
Explanation failed: %@	Erklärung fehlgeschlagen: %@
Explanation complete	Erklärung abgeschlossen
Failed to parse explanation data: %@	Erklärungsdaten konnten nicht verarbeitet werden: %@
The explanation service has not recognized your Pro status yet. Please try again.	Der Erklärungsdienst hat deinen Pro-Status noch nicht erkannt. Bitte versuche es erneut.
Explanation service error (HTTP %lld)	Fehler des Erklärungsdienstes (HTTP %lld)
The explanation service returned no initial content	Der Erklärungsdienst hat keinen ersten Inhalt zurückgegeben
Explanation Depth	Erklärungstiefe
Unlock all Read Aloud and Explain features	Alle Funktionen für Vorlesen und Erklären freischalten
Unlock unlimited Read Aloud, explanations, and premium voices.	Unbegrenztes Vorlesen, Erklärungen und Premium-Stimmen freischalten.
Failed to load subscriptions	Abonnements konnten nicht geladen werden
Subscription auto-renews. Cancel anytime in the App Store.	Das Abonnement verlängert sich automatisch. Jederzeit im App Store kündbar.
Explaining · block %1$lld/%2$lld	Erklärung · Abschnitt %1$lld/%2$lld
Generating explanation, please wait	Erklärung wird erstellt. Bitte warten.
Explanation Language	Erklärungssprache
Papers / Academic	Aufsätze / Wissenschaft
Papers, arXiv, DOI pages, and academic PDFs	Aufsätze, arXiv-, DOI-Seiten und wissenschaftliche PDFs
Settings	Einstellungen
Recognizing…	Wird erkannt …
Recognition Failed	Erkennung fehlgeschlagen
Preview	Vorschau
Preview voice	Stimme vorhören
No records in this category	Keine Einträge in dieser Kategorie
Language	Sprache
Speed	Geschwindigkeit
Manuals / Docs	Handbücher / Dokumentation
Sign in to use voice cloning.	Melde dich an, um Stimmenklonen zu verwenden.
Choose a Kindle reading position first.	Wähle zuerst eine Kindle-Leseposition.
Confirm the voice authorization first.	Bestätige zuerst die Stimmfreigabe.
Allow microphone access in System Settings.	Erlaube den Mikrofonzugriff in den Systemeinstellungen.
Scroll the Kindle library, then tap Sync again.	Scrolle durch die Kindle-Bibliothek und tippe erneut auf Synchronisieren.
Sign in to Amazon Kindle, then tap Sync.	Melde dich bei Amazon Kindle an und tippe dann auf Synchronisieren.
Read this passage naturally	Lies diesen Abschnitt natürlich vor
Record at least 3 seconds.	Nimm mindestens 3 Sekunden auf.
Debug	Debug
Account	Konto
Follow System	Systemeinstellung verwenden
Match Source	Originalsprache
Sync your Pro subscription, quota, and history across devices	Pro-Abonnement, Kontingent und Verlauf geräteübergreifend synchronisieren
Jump failed. Please try again.	Sprung fehlgeschlagen. Bitte versuche es erneut.
Enter Text	Text eingeben
Enter URL	URL eingeben
Back	Zurück
Return to Kindle Library, then Sync.	Kehre zur Kindle-Bibliothek zurück und synchronisiere.
No created voices yet	Noch keine erstellten Stimmen
No history yet	Noch kein Verlauf
No readable Kindle page is available yet	Noch keine vorlesbare Kindle-Seite verfügbar
No books synced yet	Noch keine Bücher synchronisiert
This voice no longer exists. Please create it again.	Diese Stimme ist nicht mehr vorhanden. Bitte erstelle sie erneut.
Sign Out	Abmelden
Pick a scenario — AI highlights and annotates your text	Wähle ein Szenario – die KI hebt deinen Text hervor und kommentiert ihn
You'll be asked to allow paste once you choose	Nach der Auswahl wirst du einmalig um die Erlaubnis zum Einfügen gebeten
Choose the content perspective used for imports and explanations	Wähle die Inhaltsperspektive für Importe und Erklärungen
Choose a screenshot or image	Screenshot oder Bild auswählen
Choose Source	Quelle auswählen
General	Allgemein
Reading through…	Text wird gelesen …
Overview	Übersicht
Record Again	Erneut aufnehmen
Replay	Erneut abspielen
Sign In Again	Erneut anmelden
Sign in again to enable voice cloning	Melde dich erneut an, um Stimmenklonen zu aktivieren
Retry	Erneut versuchen
Retry Explanation	Erklärung erneut versuchen
Privacy Policy	Datenschutzrichtlinie
A secure CastReader mobile session is required.	Eine sichere mobile CastReader-Sitzung ist erforderlich.
Voice	Stimme
Voice Category	Stimmenkategorie
Home	Start
System OCR does not support these languages: %@	Die System-OCR unterstützt diese Sprachen nicht: %@
Failed to initialize Kindle multilingual OCR: %@	Mehrsprachige Kindle-OCR konnte nicht initialisiert werden: %@
The next page is cached, but Kindle page sync failed. Playback is paused.	Die nächste Seite ist zwischengespeichert, aber die Kindle-Seitensynchronisierung ist fehlgeschlagen. Die Wiedergabe wurde pausiert.
Reading Kindle…	Kindle wird vorgelesen …
Couldn’t continue playback on the next page. Tap Play to continue.	Die Wiedergabe konnte auf der nächsten Seite nicht fortgesetzt werden. Tippe zum Fortfahren auf Wiedergabe.
CedReader couldn’t obtain a complete Kindle text-column mapping for this vertical Japanese page, or Kindle is in two-page mode. Read Aloud stopped before playback to avoid skipped sentences and incorrect highlighting. Switch to single-page mode and try again.	CastReader konnte für diese vertikale japanische Seite keine vollständige Textspalten-Zuordnung erhalten oder Kindle befindet sich im Doppelseitenmodus. Das Vorlesen wurde vor der Wiedergabe gestoppt, um ausgelassene Sätze und falsche Hervorhebungen zu vermeiden. Wechsle zur Einzelseitenansicht und versuche es erneut.
%@/year	%@/Jahr
About %@/week	Etwa %@/Woche
Become Pro for %@/year	Für %@/Jahr Pro werden
Make every Kindle book speak	Jedes Kindle-Buch zum Sprechen bringen
Continuous Kindle reading · 100+ professional voices · 8 languages	Kontinuierliches Kindle-Vorlesen · 100+ professionelle Stimmen · 8 Sprachen
Continuous Kindle reading · 100+ professional voices · 9 languages	Kontinuierliches Kindle-Vorlesen · 100+ professionelle Stimmen · 9 Sprachen
Monthly plan and restore purchases	Monatsplan und Käufe wiederherstellen
Renews annually. Cancel anytime.	Jährliche Verlängerung. Jederzeit kündbar.
Loading price…	Preis wird geladen …
Price unavailable	Preis nicht verfügbar
Connecting to the App Store…	Verbindung zum App Store …
View Pro plans	Pro-Tarife anzeigen
WeRead	WeRead
Your synced WeRead library	Deine synchronisierte WeRead-Bibliothek
Connect WeRead	WeRead verbinden
Sign in to sync your library and reading progress	Anmelden, um Bibliothek und Lesefortschritt zu synchronisieren
WeRead Library	WeRead-Bibliothek
Search WeRead books	WeRead-Bücher suchen
%d WeRead books synced.	%d WeRead-Bücher synchronisiert.
No WeRead books were found on this page.	Auf dieser Seite wurden keine WeRead-Bücher gefunden.
This WeRead book link has expired. Sign in again and sync your library.	Dieser WeRead-Buchlink ist abgelaufen. Melde dich erneut an und synchronisiere deine Bibliothek.
Document	Dokument
Your WeRead session has expired. Sign in again to continue.	Deine WeRead-Sitzung ist abgelaufen. Melde dich erneut an, um fortzufahren.
This book was not found in your library. Sync your WeRead library again.	Dieses Buch wurde in deiner Bibliothek nicht gefunden. Synchronisiere deine WeRead-Bibliothek erneut.
WeRead account	WeRead-Konto
Take a screenshot, then scan the QR code with WeChat	Erstelle einen Screenshot und scanne den QR-Code mit WeChat
Open WeChat Scan and choose the screenshot from Photos. After sign-in, your library opens automatically so you can sync it to CastReader.	Öffne „Scannen“ in WeChat und wähle den Screenshot aus deinen Fotos. Nach der Anmeldung wird deine Bibliothek automatisch geöffnet, damit du sie mit CastReader synchronisieren kannst.
Open WeRead and sign in.	Öffne WeRead und melde dich an.
Recently read	Zuletzt gelesen
%d books detected	%d Bücher erkannt
Scanning your WeRead library… (%d)	WeRead-Bibliothek wird durchsucht … (%d)
No library books found. Sign in on the WeRead Library page, then try again.	Keine Bücher in der Bibliothek gefunden. Melde dich auf der WeRead-Bibliotheksseite an und versuche es erneut.
Sign in, open your library, then tap Sync.	Melde dich an, öffne deine Bibliothek und tippe dann auf Synchronisieren.
Sign in to WeRead first, then tap Sync.	Melde dich zuerst bei WeRead an und tippe dann auf Synchronisieren.
%d books available to sync	%d Bücher zum Synchronisieren verfügbar
Content Services	Inhaltsdienste
After syncing, you can read aloud and explain these books in CastReader.	Nach der Synchronisierung kannst du diese Bücher in CastReader vorlesen und erklären lassen.
Sync %d Books	%d Bücher synchronisieren
This clears the local WeRead library, reading progress, and sign-in state. It does not affect your WeRead account or books.	Dadurch werden die lokale WeRead-Bibliothek, der Lesefortschritt und die Anmeldung gelöscht. Dein WeRead-Konto und deine Bücher bleiben unberührt.
Found %d WeRead books.	%d WeRead-Bücher gefunden.
Not connected	Nicht verbunden
Opening your WeRead library…	WeRead-Bibliothek wird geöffnet …
After signing in, your library will open automatically.	Nach der Anmeldung wird deine Bibliothek automatisch geöffnet.
Signed in. Opening your library…	Angemeldet. Bibliothek wird geöffnet …
Clear WeRead Sign-In	WeRead-Anmeldung löschen
Disconnect WeRead?	WeRead trennen?
Disconnect	Trennen
Disconnecting only clears CastReader's local sign-in state and library cache. It does not affect the original account or books.	Beim Trennen werden nur die lokale CastReader-Anmeldung und der Bibliothekscache gelöscht. Das ursprüngliche Konto und die Bücher bleiben unberührt.
Sign in to WeRead. Your library will open automatically afterward.	Melde dich bei WeRead an. Danach wird deine Bibliothek automatisch geöffnet.
Highlight Color	Hervorhebungsfarbe
""".strip().splitlines()
    )
)

# Correct a legacy typo while keeping the exact English source key in the catalog.
GERMAN[
    "CastReader couldn’t obtain a complete Kindle text-column mapping for this vertical Japanese page, or Kindle is in two-page mode. Read Aloud stopped before playback to avoid skipped sentences and incorrect highlighting. Switch to single-page mode and try again."
] = GERMAN.pop(
    "CedReader couldn’t obtain a complete Kindle text-column mapping for this vertical Japanese page, or Kindle is in two-page mode. Read Aloud stopped before playback to avoid skipped sentences and incorrect highlighting. Switch to single-page mode and try again."
)


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def sync_catalog(path: Path, overrides: dict[str, str] | None = None) -> tuple[int, list[str]]:
    data = json.loads(path.read_text())
    if path.name == "Localizable.xcstrings":
        old_key = "Kindle 连续朗读 · 100+ 专业音色 · 8 种语言"
        new_key = "Kindle 连续朗读 · 100+ 专业音色 · 9 种语言"
        if new_key not in data["strings"] and old_key in data["strings"]:
            data["strings"][new_key] = deepcopy(data["strings"][old_key])
        if new_key in data["strings"]:
            nine_language_values = {
                "en": "Continuous Kindle reading · 100+ professional voices · 9 languages",
                "zh-Hans": "Kindle 连续朗读 · 100+ 专业音色 · 9 种语言",
                "ja": "Kindleを連続朗読 · 100種類以上のプロ音声 · 9言語",
                "es": "Lectura continua de Kindle · Más de 100 voces profesionales · 9 idiomas",
                "fr": "Lecture Kindle en continu · Plus de 100 voix professionnelles · 9 langues",
                "de": "Kontinuierliches Kindle-Vorlesen · 100+ professionelle Stimmen · 9 Sprachen",
                "pt-BR": "Leitura contínua no Kindle · Mais de 100 vozes profissionais · 9 idiomas",
                "it": "Lettura Kindle continua · Oltre 100 voci professionali · 9 lingue",
                "hi": "लगातार Kindle वाचन · 100+ प्रोफ़ेशनल आवाज़ें · 9 भाषाएँ",
            }
            data["strings"][new_key]["localizations"] = {
                locale: unit(value) for locale, value in nine_language_values.items()
            }
    missing: list[str] = []
    for key, entry in data["strings"].items():
        localizations = entry.setdefault("localizations", {})
        english = localizations.get("en", {}).get("stringUnit", {}).get("value", key)
        german = (overrides or {}).get(key) or GERMAN.get(english)
        if german is None:
            german = english
            if english and any(character.isalpha() for character in english):
                missing.append(english)
        localizations["de"] = unit(german)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    return len(data["strings"]), missing


def main() -> None:
    count, missing = sync_catalog(ROOT / "CastReader/Localizable.xcstrings")
    info = {
        "CFBundleName": "CastReader",
        "NSCameraUsageDescription": "CastReader benötigt die Kamera, um Text aufzunehmen und vorzulesen.",
        "NSMicrophoneUsageDescription": "CastReader benötigt das Mikrofon, um ein Stimmbeispiel für das Stimmenklonen aufzunehmen.",
        "NSPhotoLibraryUsageDescription": "CastReader benötigt Zugriff auf Fotos, um Text in Bildern zu erkennen und vorzulesen.",
    }
    sync_catalog(ROOT / "CastReader/InfoPlist.xcstrings", info)
    share_overrides = {
        "Cancel": "Abbrechen",
        "Done": "Fertig",
        "Read Aloud": "Vorlesen",
        "Explain": "Erklären",
        "Send to CastReader": "An CastReader senden",
        "Choose whether CastReader should read aloud or explain this content.": "Wähle, ob CastReader diesen Inhalt vorlesen oder erklären soll.",
        "Preparing shared content…": "Geteilte Inhalte werden vorbereitet …",
        "Could not save the shared content.": "Der geteilte Inhalt konnte nicht gespeichert werden.",
        "Open CastReader to continue.": "Öffne CastReader, um fortzufahren.",
        "Shared document": "Geteiltes Dokument",
        "Shared text": "Geteilter Text",
        "Shared image": "Geteiltes Bild",
    }
    sync_catalog(ROOT / "CastReader Share Extension/Localizable.xcstrings", share_overrides)

    print(f"German app strings: {count}; English fallbacks requiring review: {len(missing)}")
    for value in missing:
        print(value)


if __name__ == "__main__":
    main()
