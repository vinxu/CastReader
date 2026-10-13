#!/usr/bin/env python3
"""Build a standalone simulator-only research bundle; no application changes."""
import concurrent.futures
import pathlib
import plistlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path('/tmp/CastReaderLanguageResearch20261011')
APP = OUT / 'LanguageResearch.app'
APP.mkdir(parents=True, exist_ok=True)
SDK = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
target = 'arm64-apple-ios17.6-simulator'
sources = list((ROOT / 'CastReader/ThirdParty/FastText').glob('*.cc'))
sources.append(ROOT / 'CastReader/Utils/NativeLanguageIdentifier.mm')

def compile_source(source):
    obj = OUT / (source.stem + '.o')
    subprocess.run(['xcrun', 'clang++', '-target', target, '-isysroot', SDK,
                    '-std=c++17', '-O2', '-c', str(source), '-o', str(obj)], check=True)
    return str(obj)

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    objects = list(pool.map(compile_source, sources))
swift_sources = [ROOT / 'scripts/language-research/Probe.swift']
swift_sources += [ROOT / ('CastReader/Utils/' + name + '.swift') for name in
                  ['SupportedTTSLanguage', 'SupplementalLanguageIdentifier', 'LanguageDetector']]
subprocess.run(['xcrun', 'swiftc', '-O', '-target', target, '-sdk', SDK,
                '-import-objc-header', str(ROOT / 'CastReader/Utils/NativeLanguageIdentifier.h'),
                *map(str, swift_sources), *objects, '-lc++', '-o', str(APP / 'LanguageResearch')], check=True)
(APP / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'ai.castreader.research.language',
    'CFBundleExecutable': 'LanguageResearch', 'CFBundlePackageType': 'APPL'}))
resources = APP / 'LanguageIdentification'
resources.mkdir(exist_ok=True)
link = resources / 'glotlid-v3-q300k.ftz'
if not link.exists():
    link.symlink_to(ROOT / 'CastReader/Resources/LanguageIdentification/glotlid-v3-q300k.ftz')
subprocess.run(['codesign', '-f', '-s', '-', str(APP)], check=True)
print(APP)
