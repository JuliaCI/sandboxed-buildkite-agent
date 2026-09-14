"""Check image staging without installing Packer or booting a VM."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ImageStagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        source = Path(__file__).resolve().parents[1]
        self.platform = self.root / 'platforms/freebsd-kvm'
        shutil.copytree(source, self.platform,
                        ignore=shutil.ignore_patterns('images', '__pycache__'))
        shutil.copy(source.parent / 'common.mk', self.platform.parent)
        self.credentials = self.root / 'credentials.pkrvars.hcl'
        self.credentials.touch()
        bindir = self.root / 'bin'
        bindir.mkdir()
        packer = bindir / 'packer'
        packer.write_text('''#!/usr/bin/env python3
import pathlib, sys
args = sys.argv[1:]
variables = dict(args[i+1].split('=', 1) for i, arg in enumerate(args) if arg == '-var')
output = pathlib.Path(variables['output_root']) / variables['arch']
assert not output.exists(), f'Output already exists: {output}'
if 'source_image' in variables:
    assert pathlib.Path(variables['source_image']).is_file(), variables['source_image']
if args[0] == 'build':
    output.mkdir(parents=True)
    if 'source_image' in variables:
        (output / 'worker.qcow2').write_text(variables['source_image'])
        (output / 'worker.qcow2-1').touch()
    else:
        (output / 'base.qcow2').touch()
''')
        packer.chmod(0o755)
        for arch in ('x86_64', 'aarch64'):
            emulator = bindir / f'qemu-system-{arch}'
            emulator.write_text('#!/bin/sh\nexit 0\n')
            emulator.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{bindir}:{os.environ["PATH"]}')

    def make(self, *args):
        result = subprocess.run(
            ['make', 'ARCH=x86_64', 'ACCELERATOR=tcg',
             f'SECRET_VARIABLES_FILE={self.credentials}', *args],
            cwd=self.platform, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def check_images(self, root):
        base = root / 'base-image/images/x86_64/base.qcow2'
        worker = root / 'buildkite-worker/images/x86_64/worker.qcow2'
        self.assertTrue(base.is_file())
        self.assertEqual(worker.read_text(), str(base))
        self.assertTrue(Path(str(worker) + '-1').is_file())

    def test_default_layout(self):
        self.make('all')
        self.check_images(self.platform)

    def test_absolute_staging_and_validation(self):
        stage = self.root / 'generation-01'
        self.make('all', f'IMAGE_ROOT={stage}')
        self.check_images(stage)
        self.assertFalse((self.platform / 'base-image/images').exists())
        self.assertFalse((self.platform / 'buildkite-worker/images').exists())
        self.make('validate', f'IMAGE_ROOT={stage}')
        self.check_images(stage)

    def test_relative_staging_and_clean_isolation(self):
        self.make('all', 'IMAGE_ROOT=generations/01')
        stage = self.platform / 'generations/01'
        self.check_images(stage)
        self.make('all', 'ARCH=aarch64', 'IMAGE_ROOT=generations/01')
        self.make('all')
        self.make('clean', 'IMAGE_ROOT=generations/01')
        self.check_images(self.platform)
        self.assertFalse((stage / 'base-image/images/x86_64').exists())
        self.assertFalse((stage / 'buildkite-worker/images/x86_64').exists())
        self.assertTrue((stage / 'base-image/images/aarch64/base.qcow2').is_file())
        self.assertTrue((stage / 'buildkite-worker/images/aarch64/worker.qcow2').is_file())


if __name__ == '__main__':
    unittest.main()
