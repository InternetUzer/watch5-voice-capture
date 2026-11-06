"""Yandex Disk REST upload adapter.

The OAuth token stays on the server. No public links are created.
"""
from __future__ import annotations

import re
from pathlib import Path
from urllib.parse import urlparse
import httpx

API_BASE = "https://cloud-api.yandex.net/v1/disk"
FOLDER_RE = re.compile(r"^disk:/[^/?#]+(?:/[^/?#]+)*$")


class YandexDiskError(RuntimeError):
    """Safe error without user credentials or signed upload URL."""


async def upload_wav(
    local_path: Path,
    remote_filename: str,
    token: str,
    folder: str = "disk:/Watch5-Voice-Capture",
    client: httpx.AsyncClient | None = None,
) -> str:
    """Create the private Disk folder and upload an existing WAV.

    A remote name is deterministic per file content, allowing retries.
    Returns disk:/... path. Intended for files <= 8 MiB.
    """
    folder = folder.rstrip("/")
    if not FOLDER_RE.fullmatch(folder) or any(part in ("", ".", "..") for part in folder[6:].split("/")):
        raise YandexDiskError("Invalid Yandex Disk folder")
    if not re.fullmatch(r"capture_[0-9]{10,16}_[a-f0-9]{12}\.wav", remote_filename):
        raise YandexDiskError("Invalid remote filename")
    if not token:
        raise YandexDiskError("Missing Yandex OAuth token")

    owned_client = client is None
    if client is None:
        client = httpx.AsyncClient(timeout=httpx.Timeout(55.0, connect=15.0), follow_redirects=False)
    headers = {"Authorization": f"OAuth {token}"}
    remote_path = folder + "/" + remote_filename

    try:
        # Each intermediate folder is created when necessary.
        segments = folder[6:].split("/")
        prefix = "disk:"
        for segment in segments:
            prefix += "/" + segment
            resp = await client.put(API_BASE + "/resources", headers=headers, params={"path": prefix})
            if resp.status_code not in (201, 409):
                raise YandexDiskError(f"Cannot create Disk folder (HTTP {resp.status_code})")

        response = await client.get(
            API_BASE + "/resources/upload",
            headers=headers,
            params={"path": remote_path, "overwrite": "true"},
        )
        if response.status_code != 200:
            raise YandexDiskError(f"Cannot obtain Disk upload URL (HTTP {response.status_code})")

        try:
            upload_url = response.json()["href"]
        except (ValueError, KeyError, TypeError) as err:
            raise YandexDiskError("Invalid Disk upload-link response") from err

        parsed = urlparse(upload_url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
            raise YandexDiskError("Untrusted Disk upload URL")

        # OAuth header must never be forwarded to the signed upload URL.
        with local_path.open("rb") as audio:
            result = await client.put(upload_url, content=audio.read())
        if result.status_code not in (200, 201, 202, 204):
            raise YandexDiskError(f"Disk upload rejected (HTTP {result.status_code})")
        return remote_path
    except (httpx.HTTPError, OSError) as err:
        raise YandexDiskError("Yandex Disk request failed") from err
    finally:
        if owned_client:
            await client.aclose()
