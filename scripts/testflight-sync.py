#!/usr/bin/env python3
"""Distribute a specific uploaded build to the existing Early Access group.

Apple beta review still gates availability. Never releases an App Store version.
"""
import argparse
import json
import time
import urllib.error
import urllib.request
from pathlib import Path
import asc

APP = '6802331047'
GROUP = '419348ce-0906-493a-ad60-7f21ee43c6ef'
ROOT = Path(__file__).resolve().parent.parent


def request(path, method='GET', data=None):
    req = urllib.request.Request('https://api.appstoreconnect.apple.com/v1/' + path,
        method=method, headers={'Authorization': 'Bearer ' + asc.token(),
        'Content-Type': 'application/json'},
        data=json.dumps(data).encode() if data is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f'{method} {path}: HTTP {exc.code}: {exc.read().decode()[:1000]}') from exc


def records(path):
    rows = []
    while path:
        result = request(path)
        rows.extend(result['data'])
        nxt = result.get('links', {}).get('next')
        path = nxt.split('/v1/', 1)[1] if nxt else None
    return rows


def patch(kind, identity, attrs):
    return request(f'{kind}/{identity}', 'PATCH', {'data': {
        'type': kind, 'id': identity, 'attributes': attrs}})


def choose_build(rows, platform, number):
    return next((b for b in rows if b['attributes']['version'] == number
                 and b['_platform'] == platform), None)


def sync(platform, number, wait):
    if not number.isdigit():
        raise ValueError('Build number must be numeric')
    deadline = time.monotonic() + wait
    while True:
        data = request(f'builds?filter[app]={APP}&filter[version]={number}&include=preReleaseVersion&limit=200')
        trains = {x['id']: x['attributes']['platform'] for x in data.get('included', [])
                  if x['type'] == 'preReleaseVersions'}
        rows = data['data']
        for b in rows:
            b['_platform'] = trains[b['relationships']['preReleaseVersion']['data']['id']]
        build = choose_build(rows, platform, number)
        if build and build['attributes']['processingState'] == 'VALID':
            break
        state = build['attributes']['processingState'] if build else 'not visible yet'
        if state in ('FAILED', 'INVALID') or time.monotonic() >= deadline:
            raise RuntimeError(f'{platform} build {number}: {state}')
        print(f'{platform} build {number}: {state}; waiting for Apple', flush=True)
        time.sleep(30)
    bid = build['id']
    if build['attributes']['expired']:
        raise RuntimeError('Refusing to distribute an expired build')
    group = request(f'betaGroups/{GROUP}')['data']['attributes']
    if group['isInternalGroup'] or group['name'] != 'Early Access':
        raise RuntimeError('Unexpected target beta group')
    detail = request(f'builds/{bid}/buildBetaDetail')['data']
    state = detail['attributes']['externalBuildState']
    allowed = {'READY_FOR_BETA_SUBMISSION', 'WAITING_FOR_BETA_REVIEW', 'IN_BETA_REVIEW',
               'BETA_APPROVED', 'READY_FOR_BETA_TESTING', 'IN_BETA_TESTING'}
    if state not in allowed:
        raise RuntimeError(f'External beta needs manual attention: {state}')
    copy = json.loads((ROOT / 'docs/testflight.json').read_text())
    for loc in records(f'apps/{APP}/betaAppLocalizations'):
        if loc['attributes']['locale'] == 'en-US':
            patch('betaAppLocalizations', loc['id'], copy['app'])
    notes = copy['test'][platform]
    locations = records(f'builds/{bid}/betaBuildLocalizations')
    loc = next((x for x in locations if x['attributes']['locale'] == 'en-US'), None)
    if loc:
        patch('betaBuildLocalizations', loc['id'], {'whatsNew': notes})
    else:
        request('betaBuildLocalizations', 'POST', {'data': {'type': 'betaBuildLocalizations',
            'attributes': {'locale': 'en-US', 'whatsNew': notes},
            'relationships': {'build': {'data': {'type': 'builds', 'id': bid}}}}})
    patch('buildBetaDetails', detail['id'], {'autoNotifyEnabled': True})
    assigned = {b['id'] for b in records(f'betaGroups/{GROUP}/builds?limit=200')}
    if bid not in assigned:
        request(f'betaGroups/{GROUP}/relationships/builds', 'POST',
                {'data': [{'type': 'builds', 'id': bid}]})
    # Re-read after assignment; Apple may advance the state as part of adding it.
    state = request(f'builds/{bid}/buildBetaDetail')['data']['attributes']['externalBuildState']
    if state == 'READY_FOR_BETA_SUBMISSION':
        request('betaAppReviewSubmissions', 'POST', {'data': {'type': 'betaAppReviewSubmissions',
            'relationships': {'build': {'data': {'type': 'builds', 'id': bid}}}}})
    result = request(f'builds/{bid}/buildBetaDetail')['data']['attributes']
    assert bid in {b['id'] for b in records(f'betaGroups/{GROUP}/builds?limit=200')}
    assert result['autoNotifyEnabled']
    assert result['externalBuildState'] in allowed - {'READY_FOR_BETA_SUBMISSION'}
    verified = records(f'builds/{bid}/betaBuildLocalizations')
    assert any(x['attributes'].get('whatsNew') == notes for x in verified)
    print(f'{platform} build {number}: Early Access assigned; auto-notify enabled; {result["externalBuildState"]}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=['IOS', 'MAC_OS'])
    parser.add_argument('--build', required=True)
    parser.add_argument('--wait', type=int, default=0)
    args = parser.parse_args()
    sync(args.platform, args.build, args.wait)
