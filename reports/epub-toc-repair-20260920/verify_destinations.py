"""Compare Swift's private EPUB corpus report to independent source XML links."""
import argparse
import json
import re
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


def compact(text):
    return re.sub(r'\s+', '', text)


def content_index(data):
    root = ET.fromstring(data)
    body = root.find('{*}body')
    chunks, anchors = [], {}

    def walk(element):
        tag = element.tag.split('}')[-1]
        if tag in ('head', 'script', 'style'):
            return
        for name in ('id', '{http://www.w3.org/XML/1998/namespace}id', 'name'):
            if element.get(name):
                anchors.setdefault(element.get(name), len(chunks))
        if tag == 'img':
            chunks.append('\ufffc')
        if element.text:
            chunks.append(element.text)
        for child in element:
            walk(child)
            if child.tail:
                chunks.append(child.tail)
    walk(body)
    return chunks, anchors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('swift_report')
    parser.add_argument('output')
    args = parser.parse_args()
    books = json.loads(Path(args.swift_report).read_text())
    results = []
    for book in books:
        with zipfile.ZipFile(book['file']) as archive:
            guide = ET.fromstring(archive.read('text/part0040.html'))
            links = [a for a in guide.iter() if a.tag.split('}')[-1] == 'a' and a.get('href')]
            rows = book['destinations']
            assert book['source'] == 'guide'
            assert len(rows) == len(links) == 40
            assert not book['unresolved']
            verified = []
            for row, link in zip(rows, links):
                path, _, fragment = ('text/' + link.get('href')).partition('#')
                assert row['title'] == ''.join(link.itertext()).strip(), row
                assert (row['path'], row['fragment']) == (path, fragment), row
                assert row['paragraph'] >= 0, row
                chunks, anchors = content_index(archive.read(path))
                expected = compact(''.join(chunks[anchors[fragment]:]))
                actual = compact(row['rendered'])
                assert actual and expected.startswith(actual[:100]), row
                verified.append({key: row[key] for key in ('title', 'path', 'fragment', 'paragraph')})
            results.append({'file': Path(book['file']).name, 'source': 'guide',
                            'verifiedDestinations': len(verified), 'unresolved': 0,
                            'method': 'ElementTree source guide links + exact id and following text, compared with production Swift paragraph prefix',
                            'destinations': verified})
    Path(args.output).write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps([{'file': r['file'], 'verified': r['verifiedDestinations']} for r in results]))


if __name__ == '__main__':
    main()
