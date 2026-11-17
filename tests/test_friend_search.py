"""Synthetic-only tests: no WeChat login, real contacts, or private cache required."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from Crypto.Cipher import AES
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'skills/wechat-find-friends/scripts/cache_image_index.py'
spec = importlib.util.spec_from_file_location('cache_index', SCRIPT)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.image = self.root / 'form.png'
        Image.new('RGB', (200, 150), 'white').save(self.image)
        self.ocr = self.root / 'fake-ocr'
        self.ocr.write_text('#!/usr/bin/env python3\nimport json,sys\n'
                            'for p in json.load(sys.stdin):\n'
                            ' print(json.dumps({"path":p,"lines":['
                            '{"text":"姓名：测试同学","confidence":0.9},'
                            '{"text":"院系：哲学系","confidence":0.9},'
                            '{"text":"年级：27本","confidence":0.9}]}))\n')
        self.ocr.chmod(0o700)
        self.manifest = self.root / 'manifest.json'
        self.index = self.root / 'index'

    def run_cli(self, *args, code=0):
        result = subprocess.run([sys.executable, str(SCRIPT), *map(str, args)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def build(self, items=None, code=0):
        if items is not None:
            self.manifest.write_text(json.dumps(items))
        return self.run_cli('index', '--manifest', self.manifest, '--out', self.index,
                            '--ocr-bin', self.ocr, '--max-side', '320', code=code)

    def find(self, *terms, code=0, name='hits.json'):
        output = self.root / name
        args = ['find', '--index', self.index, '--mode', 'all', '--output', output]
        for term in terms:
            args += ['--term', term]
        self.run_cli(*args, code=code)
        return json.loads(output.read_text())

    def test_plain_xor_v1_v2_and_invalid_layout(self):
        raw = self.image.read_bytes()
        key, xor = b'0123456789abcdef', 173

        def wrap(version, aes_key, tail_key):
            return (b'\x07\x08' + version + b'\x08\x07' + (32).to_bytes(4, 'little') +
                    (len(raw) - 32).to_bytes(4, 'little') + b'\0' +
                    AES.new(aes_key, AES.MODE_ECB).encrypt(raw[:32]) + b'\0' * 16 +
                    bytes(v ^ tail_key for v in raw[32:]))

        v2 = wrap(b'V2', key, xor)
        self.assertEqual(cache.decrypt(raw, None), raw)
        self.assertEqual(cache.decrypt(bytes(v ^ 97 for v in raw), None), raw)
        self.assertEqual(cache.decrypt(wrap(b'V1', b'cfcd208495d565ef', 201), None), raw)
        self.assertEqual(cache.decrypt(v2, (key, xor)), raw)
        for data, secret in [(v2, None), (v2[:-1], (key, xor)), (b'', None),
                             (v2, (b'fedcba9876543210', xor))]:
            with self.subTest(data_size=len(data)), self.assertRaises(ValueError):
                cache.decrypt(data, secret)

    def test_partial_index_pixel_selection_and_source_preservation(self):
        noisy = self.root / 'smaller.png'
        Image.frombytes('RGB', (40, 40), random.Random(7).randbytes(40 * 40 * 3)).save(noisy)
        self.assertGreater(noisy.stat().st_size, self.image.stat().st_size)
        bad = self.root / 'broken.dat'
        bad.write_bytes(b'not an image')
        originals = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in [self.image, noisy, bad]}
        self.build([{'id': 'readable', 'paths': [str(noisy), str(self.image)], 'ownership': 'unconfirmed'},
                    {'id': 'broken', 'paths': [str(bad)]}], code=3)
        result = self.find('哲学系', '27本', code=3)
        self.assertEqual(len(result['hits']), 1)
        self.assertEqual(result['hits'][0]['source']['path'], str(self.image))
        self.assertEqual(result['hits'][0]['context']['ownership'], 'unconfirmed')
        self.assertEqual(result['coverage'], {'total': 2, 'indexed': 1, 'unavailable': 1, 'stale': 0, 'complete': False})
        self.assertFalse(list(self.index.glob('.previews-*')))
        self.assertEqual(originals, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in originals})
        empty = self.find('未出现的姓名', code=3, name='empty.json')
        self.assertFalse(empty['hits'])
        self.assertFalse(empty['coverage']['complete'])

    def test_resume_reuses_records_but_preserves_new_context(self):
        self.build([{'id': 'one', 'paths': [str(self.image)], 'ownership': 'unconfirmed'}])
        result = self.build([{'id': 'one', 'paths': [str(self.image)], 'ownership': 'verified'}])
        self.assertEqual(json.loads(result.stdout.splitlines()[-1])['reused'], 1)
        self.assertEqual(self.find('哲学系')['hits'][0]['context']['ownership'], 'verified')

    def test_interrupted_reindex_cannot_return_old_source(self):
        self.build([{'id': 'one', 'paths': [str(self.image)]}])
        replacement = self.root / 'replacement.png'
        Image.new('RGB', (201, 151), 'black').save(replacement)
        self.manifest.write_text(json.dumps([{'id': 'one', 'paths': [str(replacement)]}]))
        args = SimpleNamespace(manifest=str(self.manifest), out=str(self.index),
                               ocr_bin=str(self.ocr), key_file=None, max_side=320,
                               max_bytes=64 * 1024 * 1024, ffmpeg=None, workers=1)
        with patch.object(cache, 'prepare', side_effect=KeyboardInterrupt), self.assertRaises(KeyboardInterrupt):
            cache.index_images(args)
        result = self.find('哲学系', code=3)
        self.assertFalse(result['hits'])
        self.assertEqual(result['coverage']['stale'], 1)

    def test_changed_source_and_render_hash_guard(self):
        self.build([{'id': 'one', 'paths': [str(self.image)]}])
        record = self.index / 'records' / (cache.sha(b'one') + '.json')
        preview = self.root / 'preview.png'
        self.run_cli('render', '--record', record, '--output', preview)
        with Image.open(preview) as im:
            self.assertEqual(im.size, (200, 150))
        self.image.write_bytes(self.image.read_bytes() + b'changed')
        self.assertEqual(self.find('哲学系', code=3)['coverage']['stale'], 1)
        target = self.root / 'must-not-render.png'
        self.run_cli('render', '--record', record, '--output', target, code=2)
        self.assertFalse(target.exists())

    def test_outputs_and_key_errors_do_not_leak_or_overwrite(self):
        self.build([{'id': 'one', 'paths': [str(self.image)]}])
        output = self.root / 'keep.json'
        output.write_text('keep')
        self.run_cli('find', '--index', self.index, '--term', '哲学系', '--output', output, code=2)
        self.assertEqual(output.read_text(), 'keep')
        key = self.root / 'bad-key.json'
        key.write_text('{"image_aes_key":"private-test-value","xor_key":-1}')
        result = self.run_cli('index', '--manifest', self.manifest, '--out', self.index,
                              '--ocr-bin', self.ocr, '--key-file', key, code=2)
        self.assertNotIn('private-test-value', result.stderr)
        self.assertNotIn('private-test-value', ''.join(p.read_text() for p in self.index.rglob('*.json')))

    def test_rejects_duplicate_ids_relative_paths_and_source_output_overlap(self):
        item = {'id': 'one', 'paths': [str(self.image)]}
        self.build([item, item], code=2)
        self.build([{'id': 'one', 'paths': ['relative.png']}], code=2)
        # A user-supplied file in the output directory may never become an input.
        self.index.mkdir(exist_ok=True)
        protected = self.index / 'source.png'
        protected.write_bytes(self.image.read_bytes())
        before = protected.read_bytes()
        self.build([{'id': 'one', 'paths': [str(protected)]}], code=2)
        self.assertEqual(protected.read_bytes(), before)

    @unittest.skipUnless(shutil.which('ffmpeg'), 'optional ffmpeg not installed')
    def test_offline_wxgf_first_frame(self):
        result = subprocess.run([shutil.which('ffmpeg'), '-v', 'error', '-i', str(self.image),
                                 '-frames:v', '1', '-pix_fmt', 'yuv420p', '-c:v', 'libx265',
                                 '-x265-params', 'pools=1:frame-threads=1', '-f', 'hevc', 'pipe:1'],
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace')[-500:])
        im = cache.image_from_bytes(b'wxgf' + b'\0' * 20 + result.stdout, shutil.which('ffmpeg'))
        self.assertEqual(im.size, (200, 150))
        im.close()


QUERY_BIN = os.environ.get('WECHAT_QUERY_BIN')


@unittest.skipUnless(QUERY_BIN, 'set WECHAT_QUERY_BIN to test the compiled macOS helper')
class SnapshotTests(unittest.TestCase):
    def row(self, path, role, title='', identifier='', y=10):
        return {'path': path, 'AXRole': role, 'AXTitle': title,
                'AXIdentifier': identifier, 'frame': [10, y, 200, 20]}

    def base(self):
        return [self.row('0.0', 'AXWindow', '微信 (窗口)'),
                self.row('0.0.0', 'AXTextArea', identifier='chat_input_field'),
                self.row('0.0.1', 'AXList', identifier='search_list')]

    def inspect(self, rows, code=0):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'ui.json'
            path.write_text(json.dumps(rows))
            p = subprocess.run([QUERY_BIN, 'inspect-snapshot', str(path)], capture_output=True, text=True)
            self.assertEqual(p.returncode, code, p.stdout + p.stderr)
            return json.loads(p.stdout)

    def test_renamed_window_and_local_sections_exclude_network(self):
        rows = self.base() + [
            self.row('0.0.1.0', 'AXStaticText', '最常使用', y=20),
            self.row('0.0.1.1', 'AXButton', '甲', 'search_item_甲', y=40),
            self.row('0.0.1.2', 'AXStaticText', '联系人', y=60),
            self.row('0.0.1.3', 'AXButton', '乙', 'search_item_乙', y=80),
            self.row('0.0.1.4', 'AXStaticText', '搜索网络结果', y=100),
            self.row('0.0.1.5', 'AXButton', '丙', 'search_item_丙', y=120)]
        result = self.inspect(rows)
        self.assertEqual(result['localCount'], 2)
        self.assertEqual(result['scope'], 'visible_results')
        self.assertEqual([m['title'] for m in result['matches']], ['甲', '乙'])

    def test_missing_unrecognized_and_valid_empty_results(self):
        for rows in [self.base()[:2], self.base(), self.base() + [
                self.row('0.0.1.0', 'AXStaticText', '加载中', y=20)]]:
            self.assertEqual(self.inspect(rows, 123)['result'], 'search_error')
        empty = self.inspect(self.base() + [self.row('0.0.1.0', 'AXStaticText', '搜索网络结果', y=20)])
        self.assertEqual(empty['localCount'], 0)

    def test_geometry_ambiguity_and_unknown_sections_fail_closed(self):
        rows = self.base() + [self.row('0.0.1.0', 'AXStaticText', '联系人', y=20)]
        rows[-1]['frame'] = [0, 0, 0, 0]
        self.inspect(rows, 123)
        self.inspect(self.base() + [self.row('0.1', 'AXWindow', '另一个窗口'),
                                   self.row('0.1.0', 'AXTextArea', identifier='chat_input_field')], 123)
        self.inspect(self.base() + [self.row('0.0.1.0', 'AXStaticText', '联系人', y=20),
                                   self.row('0.0.1.1', 'AXStaticText', '未知分区', y=40),
                                   self.row('0.0.1.2', 'AXButton', '甲', 'search_item_甲', y=60)], 123)

    def test_equal_display_names_stay_separate_nested_wrappers_do_not(self):
        rows = self.base() + [self.row('0.0.1.0', 'AXStaticText', '联系人', y=20),
                             self.row('0.0.1.1', 'AXButton', '同名', 'search_item_同名', y=40),
                             self.row('0.0.1.1.0', 'AXStaticText', '同名', 'search_item_同名', y=40),
                             self.row('0.0.1.2', 'AXButton', '同名', 'search_item_同名', y=60)]
        self.assertEqual(self.inspect(rows)['localCount'], 2)

    def test_rate_limit_but_not_quoted_chat_text(self):
        rows = self.base() + [self.row('0.0.1.0', 'AXStaticText', '联系人', y=20)]
        self.inspect(rows + [self.row('0.0.2', 'AXStaticText', '操作太频繁，请稍后再试')], 70)
        self.inspect(rows + [self.row('0.0.2', 'AXList', identifier='chat_message_list'),
                             self.row('0.0.2.0', 'AXStaticText', '操作太频繁，请稍后再试')])

    def test_help_and_unsupported_command_do_not_access_wechat(self):
        for command, code in [('--help', 0), ('send', 3)]:
            p = subprocess.run([QUERY_BIN, command], capture_output=True, text=True)
            self.assertEqual(p.returncode, code, p.stderr)


@unittest.skipUnless(os.environ.get('WECHAT_OCR_BIN'), 'set WECHAT_OCR_BIN for native Vision OCR')
class NativeOCRTests(unittest.TestCase):
    def test_chinese_form(self):
        font_path = Path('/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
        if not font_path.exists():
            self.skipTest('Chinese-capable test font unavailable')
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / 'form.png'
            im = Image.new('RGB', (1000, 650), 'white')
            draw = ImageDraw.Draw(im)
            font = ImageFont.truetype(str(font_path), 58)
            for y, text in [(70, '姓名：测试同学'), (180, '院系：哲学系'), (290, '年级：27本')]:
                draw.text((70, y), text, font=font, fill='black')
            im.save(p)
            result = subprocess.run([os.environ['WECHAT_OCR_BIN']], input=json.dumps([str(p)]),
                                    text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            value = json.loads(result.stdout)
            self.assertIn('哲学系', ''.join(line['text'] for line in value['lines']))


if __name__ == '__main__':
    unittest.main()
