"""Upload and verify private Yandex Disk objects before authorizing local deletion."""
from __future__ import annotations

import asyncio
import hashlib
import json
import re
from pathlib import Path
from datetime import datetime, timezone
from urllib.parse import urlparse
import httpx
from .wav_metadata import read_timeline

API_BASE = 'https://cloud-api.yandex.net/v1/disk'
FOLDER_RE = re.compile(r'^disk:/[^/?#]+(?:/[^/?#]+)*$')


class YandexDiskError(RuntimeError):
    """Safe error without credentials or signed URLs."""


async def _put_verified(client, remote_path, payload, headers):
    response = await client.get(API_BASE + '/resources/upload', headers=headers,
                                params={'path': remote_path, 'overwrite': 'true'})
    if response.status_code != 200:
        raise YandexDiskError('Cannot obtain Disk upload URL')
    try:
        upload_url = response.json()['href']
        parsed = urlparse(upload_url)
    except (ValueError, KeyError, TypeError) as err:
        raise YandexDiskError('Invalid upload link') from err
    hostname = parsed.hostname or ''
    if (parsed.scheme != 'https' or parsed.username or parsed.password or
        not any(hostname.endswith(suffix) for suffix in ('.yandex.ru', '.yandex.net', '.yandex.com'))):
        raise YandexDiskError('Untrusted Disk upload URL')
    # OAuth must not be forwarded to the signed upload host.
    result = await client.put(upload_url, content=payload)
    if result.status_code not in (200, 201, 202, 204):
        raise YandexDiskError('Disk upload rejected')
    expected = hashlib.sha256(payload).hexdigest()
    for attempt in range(3):
        info = await client.get(API_BASE + '/resources', headers=headers,
                                params={'path': remote_path, 'fields': 'type,size,sha256'})
        if info.status_code == 200:
            try:
                value = info.json()
                if (value.get('type') == 'file' and value.get('size') == len(payload)
                    and value.get('sha256') == expected):
                    return
            except (ValueError, AttributeError):
                pass
        if attempt < 2:
            await asyncio.sleep(0.4 * (attempt + 1))
    raise YandexDiskError('Disk file verification failed; retain local recording')


async def upload_wav(local_path: Path, remote_filename: str, token: str,
                     folder: str = 'disk:/Watch5-Voice-Capture',
                     client: httpx.AsyncClient | None = None) -> str:
    folder = folder.rstrip('/')
    if not FOLDER_RE.fullmatch(folder) or any(part in ('', '.', '..') for part in folder[6:].split('/')):
        raise YandexDiskError('Invalid Yandex Disk folder')
    if not re.fullmatch(r'capture_[0-9]{10,16}_[a-f0-9]{12}\.wav', remote_filename):
        raise YandexDiskError('Invalid remote filename')
    if not token:
        raise YandexDiskError('Missing Yandex OAuth token')
    try:
        timeline = read_timeline(local_path)
    except ValueError as err:
        raise YandexDiskError('Invalid WAV') from err
    # Human-readable start time alongside the original stable identifier and hash.
    # v1 files retain their old cloud path; v2 embeds exact timing across silent gaps.
    if timeline and timeline.get('segments'):
        timestamp = timeline['segments'][0]['started_at_ms'] / 1000
        if 0 <= timestamp <= 4102444800:
            stamp = datetime.fromtimestamp(timestamp, timezone.utc).strftime('%Y-%m-%d_%H-%M-%S_UTC')
            remote_filename = stamp + '_' + remote_filename
    owned = client is None
    if client is None:
        client = httpx.AsyncClient(timeout=httpx.Timeout(150, connect=15), follow_redirects=False)
    headers = {'Authorization': f'OAuth {token}'}
    remote_path = folder + '/' + remote_filename
    try:
        prefix = 'disk:'
        for segment in folder[6:].split('/'):
            prefix += '/' + segment
            response = await client.put(API_BASE + '/resources', headers=headers, params={'path': prefix})
            if response.status_code not in (201, 409):
                raise YandexDiskError('Cannot create Disk folder')
        access = await client.get(API_BASE + '/resources', headers=headers,
                                  params={'path': folder, 'fields': 'type'})
        if access.status_code in (401, 403):
            raise YandexDiskError('Yandex Disk read access is required for file verification')
        if access.status_code != 200:
            raise YandexDiskError('Cannot check Disk folder access')
        await _put_verified(client, remote_path, local_path.read_bytes(), headers)
        if timeline is not None:
            # The timeline is also embedded in the WAV: retries always reproduce both files.
            payload = json.dumps(timeline, ensure_ascii=False, indent=2).encode('utf-8')
            await _put_verified(client, remote_path[:-4] + '.timeline.json', payload, headers)
        return remote_path
    except (httpx.HTTPError, OSError) as err:
        raise YandexDiskError('Yandex Disk request failed') from err
    finally:
        if owned:
            await client.aclose()
