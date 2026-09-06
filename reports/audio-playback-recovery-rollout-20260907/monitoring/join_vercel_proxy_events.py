#!/usr/bin/env python3
"""Join already sanitized Vercel/proxy snapshots, never raw runtime logs."""
import argparse
from collections import Counter, defaultdict
from datetime import datetime
import json
from pathlib import Path


def utc(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def join(vercel, proxy):
    if vercel.get('schema') != 'castreader.vercel-preset-event-window.v1' or proxy.get('schema') != 'castreader.us-proxy-event-window.v1':
        raise ValueError('unexpected_sanitized_schema')
    start = utc(vercel['window']['requestStartInclusiveUTC'])
    end = utc(vercel['window']['requestStartExclusiveUTC'])
    proxy_covers_window = utc(proxy['window']['startUTC']) <= start < end <= utc(proxy['window']['endUTCExclusive'])
    proxy_index = defaultdict(list)
    for row in proxy['anonymousRequests']:
        proxy_index[(row['requestKey'], row.get('attempt'))].append(row)
    application_providers = defaultdict(set)
    for row in vercel['requests']:
        for key in row['applicationRequestKeys']:
            application_providers[key].add(row['vercelRequestKey'])
    result = []
    for request in vercel['requests']:
        started = {(event['requestKey'], event['attempt']) for event in request['events'] if event['event'] == 'attempt_start'}
        for key, attempt in sorted(started):
            matches = proxy_index.get((key, attempt), [])
            ambiguous = len(matches) > 1 or len(application_providers[key]) > 1 or any(row['ambiguousRepeatedRequestKey'] for row in matches)
            row = {'vercelRequestKey': request['vercelRequestKey'], 'requestStartUTC': request['requestStartUTC'],
                'requestKey': key, 'attempt': attempt, 'vercelStatus': request.get('status'),
                'matchCount': len(matches), 'ambiguous': ambiguous, 'proxy': []}
            for match in matches:
                row['proxy'].append({name: match[name] for name in ('firstUTC', 'lastUTC', 'receivedEvents', 'phases', 'flightKeys', 'outcomes')})
            result.append(row)
    count = Counter()
    for row in result:
        count['attempts'] += 1
        count['matched' if row['matchCount'] else 'unmatched'] += 1
        count['ambiguous'] += row['ambiguous']
        if row['matchCount'] == 1 and not row['ambiguous']:
            outcomes = row['proxy'][0]['outcomes']
            count['matchedProxyComplete'] += bool(outcomes.get('complete'))
    return {'schema': 'castreader.vercel-proxy-anonymous-join.v1', 'readOnly': True,
        'productionModified': False, 'rawContentExported': False,
        'expectedDeployment': vercel['expectedDeployment'], 'window': vercel['window'],
        'coverage': {'vercel': vercel['coverage'], 'proxyCoversWindow': proxy_covers_window,
            'proxyRuntimeVerified': proxy['runtime']['verified'],
            'proxyCoverageComplete': proxy['coverage']['complete'],
            'proxyAnonymousRequestsTruncated': proxy['anonymousRequestsTruncated'],
            'proxyEventDetailTruncationIgnoredForJoin': proxy['eventsTruncated']},
        'counts': dict(count), 'attempts': result,
        'limitations': [
            'Correlation uses application requestKey + attempt, never provider ID or timing alone.',
            'Application key reuse across Vercel invocations or duplicate proxy groups is marked ambiguous.',
            'The complete proxy anonymous request-group list is used; its truncated event-detail list is not the join source.',
            'A matched complete upstream request is not evidence of audio decode quality or successful user playback.',
        ]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vercel', type=Path, required=True)
    parser.add_argument('--proxy', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = join(json.loads(args.vercel.read_text()), json.loads(args.proxy.read_text()))
    result['sources'] = {'vercelSnapshot': str(args.vercel), 'proxySnapshot': str(args.proxy)}
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps({'saved': str(args.output), 'counts': result['counts'], 'coverage': result['coverage']}))


if __name__ == '__main__':
    main()
