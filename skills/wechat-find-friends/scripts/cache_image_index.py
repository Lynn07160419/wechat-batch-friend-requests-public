#!/usr/bin/env python3
"""Index an explicit local image manifest; never connects to WeChat or the network."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile

VERSION = 2
MAGICS = (b'\xff\xd8\xff', b'\x89PNG', b'GIF8', b'RIFF', b'BM', b'II*\0', b'MM\0*', b'wxgf')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(value, f, ensure_ascii=False, indent=2)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load_key(path):
    if not path:
        return None
    try:
        value = json.loads(Path(path).read_text())
        key, xor = value['image_aes_key'], value['xor_key']
        if not isinstance(key, str) or type(xor) is not int or not 0 <= xor <= 255:
            raise ValueError()
        raw = key.encode('ascii') if len(key) == 16 else bytes.fromhex(key)
        if len(raw) not in (16, 24, 32):
            raise ValueError()
        return raw, xor
    except Exception:
        raise ValueError('Invalid existing image-key file; key contents are not logged') from None


def known(data):
    return data.startswith(MAGICS) or (len(data) >= 12 and data[4:8] == b'ftyp')


def decrypt(data, key):
    if known(data):
        return data
    if data[:6] in (b'\x07\x08V1\x08\x07', b'\x07\x08V2\x08\x07'):
        if len(data) < 31:
            raise ValueError('unsupported_or_truncated_header')
        aes_n, xor_n = struct.unpack('<II', data[6:14])
        if aes_n <= 0 or aes_n % 16 or 15 + aes_n + 16 + xor_n > len(data):
            raise ValueError('unsupported_or_truncated_layout')
        if data[:6] == b'\x07\x08V1\x08\x07':
            image_key, xor = b'cfcd208495d565ef', 0xC9
        elif key is None:
            raise ValueError('missing_image_key')
        else:
            image_key, xor = key
        try:
            from Crypto.Cipher import AES
        except ImportError:
            raise ValueError('pycryptodome_unavailable') from None
        head = AES.new(image_key, AES.MODE_ECB).decrypt(data[15:15 + aes_n])
        if not known(head):
            raise ValueError('key_mismatch_or_damaged_image')
        tail = data[15 + aes_n + 16:15 + aes_n + 16 + xor_n]
        return head + tail.translate(bytes(i ^ xor for i in range(256)))
    if data:
        for magic in MAGICS:
            xor = data[0] ^ magic[0]
            if bytes(v ^ xor for v in data[:len(magic)]) == magic:
                return data.translate(bytes(i ^ xor for i in range(256)))
    raise ValueError('unsupported_image_format')


def image_from_bytes(raw, ffmpeg):
    from PIL import Image, ImageOps
    if raw.startswith(b'wxgf'):
        if not ffmpeg:
            raise ValueError('wxgf_requires_existing_ffmpeg')
        # Offline Annex-B extraction; see https://sarv.blog/posts/wxam/ .
        starts = [m.start() for m in re.finditer(b'\x00\x00\x00?\x01', raw)
                  if m.end() + 1 < len(raw) and (raw[m.end()] >> 1) & 63 == 32]
        for start in starts[:8]:
            result = subprocess.run(
                [ffmpeg, '-v', 'error', '-threads', '1', '-f', 'hevc', '-i', 'pipe:0',
                 '-frames:v', '1', '-f', 'image2pipe', '-vcodec', 'png', 'pipe:1'],
                input=raw[start:], capture_output=True, timeout=20)
            if result.stdout:
                try:
                    with Image.open(io.BytesIO(result.stdout)) as im:
                        im.load()
                        return im.convert('RGB')
                except Exception:
                    continue
        raise ValueError('unsupported_or_damaged_wxgf')
    with Image.open(io.BytesIO(raw)) as im:
        im.load()
        return ImageOps.exif_transpose(im).convert('RGB')


def file_state(path):
    path = Path(path)
    if not path.is_absolute():
        raise ValueError('Manifest source paths must be absolute')
    try:
        st = path.stat()
        return {'path': str(path), 'bytes': st.st_size, 'mtime_ns': st.st_mtime_ns}
    except OSError:
        return {'path': str(path), 'missing': True}


def prepare(job, key, ffmpeg, config, preview_dir):
    item, states, record_file = job
    record = {'id': item['id'], 'context': {k: v for k, v in item.items() if k not in ('id', 'paths')},
              'inputs': states, 'config': config, 'status': 'unsupported', 'errors': [],
              'frame_scope': 'first_frame', 'checked_at': datetime.now(timezone.utc).isoformat()}
    best, best_meta = None, None
    for before in states:
        try:
            if before.get('missing'):
                raise ValueError('source_missing')
            if before['bytes'] > config['max_bytes']:
                raise ValueError('source_exceeds_max_bytes')
            raw = Path(before['path']).read_bytes()
            if file_state(before['path']) != before:
                raise ValueError('source_changed_during_read')
            im = image_from_bytes(decrypt(raw, key), ffmpeg)
            if best is None or im.width * im.height > best.width * best.height:
                if best is not None:
                    best.close()
                best = im
                best_meta = {'path': before['path'], 'sha256': sha(raw), 'bytes': len(raw),
                             'mtime_ns': before['mtime_ns'], 'size': list(im.size)}
            else:
                im.close()
        except Exception as exc:
            record['errors'].append({'path': before['path'], 'reason': str(exc)[:300]})
    if best is None:
        return record, record_file, None
    record['source'] = best_meta
    factor = min(4.0, config['max_side'] / max(best.size))
    preview = best.resize((max(1, round(best.width * factor)), max(1, round(best.height * factor))))
    target = preview_dir / (sha(item['id'].encode()) + '.png')
    preview.save(target)
    preview.close()
    best.close()
    return record, record_file, target


def index_images(args):
    from PIL import Image  # Fail before scanning if the selected runtime lacks Pillow.
    del Image
    manifest = json.loads(Path(args.manifest).read_text())
    if not isinstance(manifest, list):
        raise ValueError('Manifest must be a JSON array')
    ids = set()
    for item in manifest:
        if not isinstance(item, dict) or not isinstance(item.get('id'), str) or not item['id']:
            raise ValueError('Each manifest item needs a nonempty string id')
        if item['id'] in ids:
            raise ValueError('Duplicate manifest id')
        ids.add(item['id'])
        if not isinstance(item.get('paths'), list) or not item['paths'] or not all(isinstance(p, str) for p in item['paths']):
            raise ValueError('Each manifest item needs nonempty paths')
    ocr = Path(args.ocr_bin).resolve(strict=True)
    key = load_key(args.key_file)
    out = Path(args.out).resolve()
    if out.exists() and any(out.iterdir()) and not (out / 'meta.json').exists():
        raise ValueError('Use a new output directory or an existing image-index directory')
    if (out / 'meta.json').exists() and json.loads((out / 'meta.json').read_text()).get('kind') != 'wechat_local_image_index':
        raise ValueError('Output directory belongs to a different application')
    out.mkdir(parents=True, exist_ok=True, mode=0o700)
    records_dir = out / 'records'
    records_dir.mkdir(exist_ok=True, mode=0o700)
    config = {'version': VERSION, 'ocr_sha256': sha(ocr.read_bytes()), 'max_side': args.max_side,
              'max_bytes': args.max_bytes}
    # Prevent an output directory from shadowing source files.
    for item in manifest:
        for p in item['paths']:
            resolved = Path(p).resolve()
            if resolved == out or out in resolved.parents:
                raise ValueError('Index output directory cannot contain input source files')
    jobs, reused = [], 0
    inputs_by_id = {}
    for item in manifest:
        states = [file_state(p) for p in item['paths']]
        inputs_by_id[item['id']] = states
        target = records_dir / (sha(item['id'].encode()) + '.json')
        existing = json.loads(target.read_text()) if target.exists() else None
        if existing and existing.get('status') == 'indexed' and existing.get('inputs') == states and existing.get('config') == config:
            existing['context'] = {k: v for k, v in item.items() if k not in ('id', 'paths')}
            write_json(target, existing)
            reused += 1
        else:
            jobs.append((item, states, target))
    # Publishing expected fingerprints makes interrupted runs distinguishable from
    # older successful records, including when an ID is reused for another file.
    write_json(out / 'meta.json', {'kind': 'wechat_local_image_index', 'version': VERSION,
                                 'config': config, 'manifest_ids': [i['id'] for i in manifest],
                                 'inputs_by_id': inputs_by_id})
    done, failed = reused, 0
    with tempfile.TemporaryDirectory(prefix='.previews-', dir=out) as temp, ThreadPoolExecutor(max_workers=args.workers) as pool:
        for start in range(0, len(jobs), 24):
            batch = list(pool.map(lambda j: prepare(j, key, args.ffmpeg, config, Path(temp)), jobs[start:start + 24]))
            paths = [str(p) for _, _, p in batch if p]
            recognized = {}
            ocr_error = None
            if paths:
                try:
                    proc = subprocess.run([str(ocr)], input=json.dumps(paths), text=True, capture_output=True, check=True, timeout=120)
                    for line in proc.stdout.splitlines():
                        value = json.loads(line)
                        recognized[value['path']] = value
                except Exception as exc:
                    ocr_error = type(exc).__name__
            for record, target, preview in batch:
                if preview:
                    result = recognized.get(str(preview))
                    if result is not None and not result.get('error') and isinstance(result.get('lines'), list):
                        record.update(status='indexed', lines=result['lines'])
                    else:
                        record.update(status='ocr_error', ocr_error=ocr_error or (result or {}).get('error', 'missing_ocr_result'))
                    preview.unlink()  # This path was generated inside this run's private temp dir.
                failed += record['status'] != 'indexed'
                write_json(target, record)
                done += 1
            print(json.dumps({'completed': done, 'total': len(manifest), 'reused': reused, 'failed': failed}), flush=True)
    print(json.dumps({'completed': done, 'total': len(manifest), 'reused': reused, 'failed': failed}), flush=True)
    return 3 if failed else 0


def normalize(text):
    return ''.join(text.split()).casefold()


def find_images(args):
    if Path(args.output).exists():
        raise ValueError('Search output already exists; choose a new file')
    out = Path(args.index)
    meta = json.loads((out / 'meta.json').read_text())
    if meta.get('kind') != 'wechat_local_image_index' or meta.get('version') != VERSION:
        raise ValueError('Unsupported index version; rerun index with the original manifest')
    hits = []
    coverage = {'total': len(meta['manifest_ids']), 'indexed': 0, 'unavailable': 0, 'stale': 0}
    for image_id in meta['manifest_ids']:
        path = out / 'records' / (sha(image_id.encode()) + '.json')
        if not path.exists():
            coverage['unavailable'] += 1
            continue
        record = json.loads(path.read_text())
        if record.get('status') != 'indexed':
            coverage['unavailable'] += 1
            continue
        if (record.get('config') != meta['config'] or
                record.get('inputs') != meta['inputs_by_id'].get(image_id) or
                any(file_state(s['path']) != s for s in record['inputs'])):
            coverage['stale'] += 1
            continue
        coverage['indexed'] += 1
        text = ''.join(line['text'] for line in record['lines'])
        terms = [term for term in args.term if normalize(term) in normalize(text)]
        if terms and (args.mode == 'any' or len(terms) == len(args.term)):
            hits.append({'id': image_id, 'record': str(path.resolve()), 'source': record['source'],
                         'context': record.get('context', {}), 'matched_terms': terms,
                         'matched_lines': [line for line in record['lines'] if any(normalize(term) in normalize(line['text']) for term in terms)]})
    coverage['complete'] = coverage['indexed'] == coverage['total']
    write_json(args.output, {'mode': args.mode, 'terms': args.term, 'coverage': coverage, 'hits': hits})
    print(json.dumps({'matches': len(hits), 'coverage': coverage, 'output': str(Path(args.output).resolve())}))
    return 0 if coverage['complete'] else 3


def render_image(args):
    record = json.loads(Path(args.record).read_text())
    source = record['source']
    target = Path(args.output)
    if target.exists():
        raise ValueError('Render output already exists; choose a new file')
    raw = Path(source['path']).read_bytes()
    if sha(raw) != source['sha256']:
        raise ValueError('Source changed since indexing; reindex before rendering')
    image = image_from_bytes(decrypt(raw, load_key(args.key_file)), args.ffmpeg)
    target.parent.mkdir(parents=True, exist_ok=True)
    image.save(target, format='PNG')
    image.close()
    print(json.dumps({'output': str(target.resolve())}))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('index')
    p.add_argument('--manifest', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--ocr-bin', required=True)
    p.add_argument('--workers', type=int, choices=range(1, 5), default=2)
    p.add_argument('--max-side', type=int, default=2400)
    p.add_argument('--max-bytes', type=int, default=64 * 1024 * 1024)
    p.add_argument('--key-file')
    p.add_argument('--ffmpeg', default=shutil.which('ffmpeg'))
    p.set_defaults(func=index_images)
    p = sub.add_parser('find')
    p.add_argument('--index', required=True)
    p.add_argument('--term', action='append', required=True)
    p.add_argument('--mode', choices=['any', 'all'], default='any')
    p.add_argument('--output', required=True)
    p.set_defaults(func=find_images)
    p = sub.add_parser('render')
    p.add_argument('--record', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--key-file')
    p.add_argument('--ffmpeg', default=shutil.which('ffmpeg'))
    p.set_defaults(func=render_image)
    args = parser.parse_args()
    if getattr(args, 'max_side', 1) <= 0 or getattr(args, 'max_bytes', 1) <= 0:
        parser.error('Size limits must be positive')
    if hasattr(args, 'term') and any(not normalize(t) for t in args.term):
        parser.error('Search terms cannot be empty')
    try:
        return args.func(args)
    except Exception as exc:
        parser.exit(2, f'{type(exc).__name__}: {exc}\n')


if __name__ == '__main__':
    raise SystemExit(main())
