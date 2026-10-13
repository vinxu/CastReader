import json, hashlib, copy, pathlib
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=pathlib.Path(__file__).parent
before=json.loads((OUT/'online-before.json').read_text())
source=json.loads((OUT/'editorial-copy.json').read_text())
catalog=json.loads((ROOT/'docs/aso/search-localizations.json').read_text())
rows=catalog['localizations']
changes={
 'fr-FR': {'name':'CastReader: Lecteur de texte','subtitle':'PDF, livres et lecture vocale','keywords':'tts,synthèse,voix,ocr,scanner,epub,articles,documents,étude,dyslexie,audio,prononciation'},
 'pt-BR': {'name':'CastReader: Texto para Voz','subtitle':'Ouça PDF, livros e páginas web'},
 'it': {'name':'CastReader: Leggi ad alta voce','keywords':'tts,sintesi,testo,lettore,ocr,scanner,epub,articoli,documenti,studio,dislessia,audiolibri'},
 'hi': {'keywords':'पढ़कर सुनाना,स्कैन,text to speech,tts,ocr,epub,पाठक'},
 'ro': {'name':'CastReader: Text în vorbire','keywords':'citire cu voce tare,ocr,scanare,epub,documente,studiu,dislexie,audiobook,cititor,lectură'},
 'no': {'subtitle':'Lytt til PDF og bøker','keywords':'tekst til tale,opplesning,stemme,ocr,skanner,epub,artikler,dokumenter,nettsider,dysleksi,lydbok'},
 'hu': {'subtitle':'Hallgass PDF-et és könyveket','keywords':'szöveg,beszéd,hang,ocr,szkenner,epub,cikkek,tanulás,diszlexia,weboldal'}
}
for locale,fields in changes.items(): rows[locale].update(fields)
for locale,query in [('fr-FR','lecteur de texte'),('pt-BR','texto para voz'),('it','leggi ad alta voce'),('hi','text to speech')]:
 if query not in rows[locale]['searchQueries']:rows[locale]['searchQueries'].append(query)
catalog['revision']='2026-10-11-full-copy-v2'
catalog['descriptionCatalog']='ios-description-localizations.json'
# Published metadata is separate from reviewed source. All snapshots are immutable evidence.
ios=next(v for v in before['versions'] if v['version']['attributes']['platform']=='IOS')
old={r['attributes']['locale']:r['attributes'] for r in ios['localizations']}
assert set(rows)==set(old)==set(source)
descriptions={'schemaVersion':1,'revision':catalog['revision'],'platform':'IOS','reviewedForVersion':'1.2.49','sourceSnapshot':'reports/aso-full-copy-20261011/online-before.json','scope':'Description only. Promotional text, whatsNew and URLs are preserved. Search fields live in search-localizations.json.','localizations':{}}
protected=[]
for locale,row in rows.items():
 b=old[locale]['description'].strip().split('\n\n'); e=source[locale]
 if len(b)==18:
  content=b[6]+'\n'+b[7]; disclaimer=b[8];language=b[11]+'\n'+b[12];tail=b[13:]
 elif len(b)==12:
  content=b[4];disclaimer=b[5];language=b[6];tail=b[7:]
 elif locale=='zh-Hant' and len(b)==11:
  content=b[4];disclaimer=b[5];language=b[6];tail=b[7:]
 else:raise ValueError((locale,len(b)))
 # Exact original restrictions, financial terms, privacy and EULA; two Hungarian grammar fixes only.
 originals=[disclaimer]+tail
 edits=[]
 if locale=='hu':
  corrected=[]
  for block in tail:
   new=block.replace('a App Storeen','az App Store-ban')
   if new!=block:edits.append({'before':block,'after':new,'reason':'Hungarian article/suffix grammar only; no entitlement changes'})
   corrected.append(new)
  tail=corrected
 if locale=='es-MX':content=content.replace('vídeo','video')
 if 'language' in e:language=e['language'].replace('语言：中国地区','语言；中国地区')
 else:language=e['languageHeading']+'\n'+language.split('\n',1)[1]
 full='\n\n'.join([e['intro'],e['read'],e['explain'],content,disclaimer,b[0],language]+tail)
 descriptions['localizations'][locale]={'description':full,'reviewNote':e['note'],'searchIntent':row['searchQueries'],'source':row['terminologySource']}
 protected.append({'locale':locale,'sourceParagraphs':originals,'permittedGrammarEdits':edits,'retainedHashes':[hashlib.sha256(s.encode()).hexdigest() for s in [disclaimer]+tail]})
 print(locale,'name',len(row['name']),'subtitle',len(row['subtitle']),'keywords',len(row['keywords'].encode()),'description',len(full))
 assert len(full)<=4000,(locale,len(full))
 assert len(row['name'])<=30 and len(row['subtitle'])<=30 and len(row['keywords'].encode())<=100,locale
(ROOT/'docs/aso/search-localizations.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
(ROOT/'docs/aso/ios-description-localizations.json').write_text(json.dumps(descriptions,ensure_ascii=False,indent=2)+'\n')
approved=json.loads((ROOT/'docs/aso/approved-keywords.json').read_text())
for locale,row in rows.items():approved[locale]=row['keywords']
(ROOT/'docs/aso/approved-keywords.json').write_text(json.dumps(approved,ensure_ascii=False,indent=2)+'\n')
(OUT/'protected-paragraphs.json').write_text(json.dumps(protected,ensure_ascii=False,indent=2)+'\n')
