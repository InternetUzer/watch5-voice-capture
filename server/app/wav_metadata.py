"""Strict PCM WAV validation and optional capture timeline extraction."""
import json
import math
import struct
from pathlib import Path

MAX_BYTES = 24 * 1024 * 1024
MAX_PCM_BYTES = 16000 * 2 * 600


def read_timeline(path: Path) -> dict | None:
    size = path.stat().st_size
    timeline = None
    data_size = None
    fmt = None
    with path.open('rb') as handle:
        header = handle.read(12)
        if len(header) != 12 or header[:4] != b'RIFF' or header[8:] != b'WAVE':
            raise ValueError('Invalid WAV header')
        if struct.unpack('<I', header[4:8])[0] != size - 8:
            raise ValueError('Incomplete WAV')
        while handle.tell() < size:
            chunk = handle.read(8)
            if len(chunk) != 8:
                raise ValueError('Incomplete WAV chunk')
            name, length = struct.unpack('<4sI', chunk)
            if handle.tell() + length + (length % 2) > size:
                raise ValueError('WAV chunk exceeds file')
            if name == b'fmt ':
                if fmt is not None or length != 16:
                    raise ValueError('Expected PCM format')
                fmt = struct.unpack('<HHIIHH', handle.read(length))
            elif name == b'data':
                if data_size is not None or not 0 < length <= MAX_PCM_BYTES or length % 2:
                    raise ValueError('Invalid PCM length')
                data_size = length
                handle.seek(length, 1)
            elif name == b'vcap':
                if timeline is not None or length > 512 * 1024:
                    raise ValueError('Invalid timeline length')
                try:
                    timeline = json.loads(handle.read(length))
                except (ValueError, UnicodeError) as err:
                    raise ValueError('Invalid timeline JSON') from err
            else:
                handle.seek(length, 1)
            if length % 2:
                handle.read(1)
    if fmt != (1, 1, 16000, 32000, 2, 16) or data_size is None:
        raise ValueError('Expected PCM16 mono 16 kHz WAV')
    if timeline is not None:
        validate_timeline(timeline, data_size / 32)
    return timeline


def validate_timeline(value, duration_ms):
    if not isinstance(value, dict) or value.get('version') != 1:
        raise ValueError('Unsupported timeline')
    if not isinstance(value.get('recovered', False), bool):
        raise ValueError('Invalid recovery flag')
    segments = value.get('segments')
    if not isinstance(segments, list) or len(segments) > 10000:
        raise ValueError('Invalid timeline segments')
    end = 0
    for segment in segments:
        if not isinstance(segment, dict):
            raise ValueError('Invalid segment')
        for key in ('audio_start_ms', 'audio_end_ms', 'started_at_ms', 'ended_at_ms'):
            n = segment.get(key)
            if isinstance(n, bool) or not isinstance(n, (float, int)) or not math.isfinite(n):
                raise ValueError('Invalid timestamp')
        begin, finish = segment['audio_start_ms'], segment['audio_end_ms']
        if not value.get('recovered', False) and abs(begin - end) > 0.01:
            raise ValueError('Gap in audio timeline')
        if begin < end or finish <= begin or finish > duration_ms + 0.01:
            raise ValueError('Invalid audio range')
        if abs((segment['ended_at_ms'] - segment['started_at_ms']) - (finish - begin)) > 0.1:
            raise ValueError('Timeline duration mismatch')
        if segment.get('source') not in ('watch', 'headset', 'unknown'):
            raise ValueError('Invalid audio source')
        end = finish
    if not value.get('recovered', False) and (not segments or abs(end - duration_ms) > 0.01):
        raise ValueError('Incomplete timeline')
