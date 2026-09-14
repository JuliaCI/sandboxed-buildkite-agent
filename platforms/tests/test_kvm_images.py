"""Check image staging without installing Packer or booting a VM."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ImageStagingChecks:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        source = Path(__file__).resolve().parents[1] / self.platform_name
        self.platform = self.root / 'platforms' / self.platform_name
        shutil.copytree(source, self.platform,
                        ignore=shutil.ignore_patterns('images', 'downloads', 'virtio-win', '__pycache__'))
        for helper in ('common.mk', 'kvm-images.mk'):
            shutil.copy(source.parent / helper, self.platform.parent)
        self.credentials = self.root / 'credentials.pkrvars.hcl'
        self.credentials.touch()
        bindir = self.root / 'bin'
        bindir.mkdir()
        packer = bindir / 'packer'
        packer.write_text('''#!/usr/bin/env python3
import pathlib, shutil, sys
args = sys.argv[1:]
variables = dict(args[i+1].split('=', 1) for i, arg in enumerate(args) if arg == '-var')
output = pathlib.Path(variables['output_root']) / variables.get('arch', '')
if '-force' in args and output.exists():
    shutil.rmtree(output)
assert not output.exists(), f'Output already exists: {output}'
if 'source_image' in variables:
    assert pathlib.Path(variables['source_image']).is_file(), variables['source_image']
if args[0] == 'build':
    socket = pathlib.Path(variables['qmp_socket_path'])
    assert len(str(socket)) < 100, socket
    assert socket.parent.is_dir(), socket
    assert socket.parent.stat().st_mode & 0o777 == 0o700
    socket.touch()
    output.mkdir(parents=True)
    if args[-1] == 'kvm_machine.pkr.hcl':
        (output / 'worker.qcow2').write_text(variables['source_image'])
        (output / 'worker.qcow2-1').touch()
    else:
        (output / 'base.qcow2').write_text(variables.get('source_image', ''))
    (output / 'qmp-path').write_text(str(socket))
''')
        packer.chmod(0o755)
        for arch in ('x86_64', 'aarch64'):
            emulator = bindir / f'qemu-system-{arch}'
            emulator.write_text('#!/bin/sh\nexit 0\n')
            emulator.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{bindir}:{os.environ["PATH"]}')

    def make(self, *args, succeeds=True):
        result = subprocess.run(
            ['make', '-o', 'check-tools', 'ARCH=x86_64', 'ACCELERATOR=tcg',
             f'SECRET_VARIABLES_FILE={self.credentials}', *args],
            cwd=self.platform, env=self.env, text=True, capture_output=True)
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def check_images(self, root):
        base = root / 'base-image/images' / self.image_subdir / 'base.qcow2'
        worker = root / 'buildkite-worker/images' / self.image_subdir / 'worker.qcow2'
        self.assertTrue(base.is_file())
        for disk in (base, worker):
            socket = Path((disk.parent / 'qmp-path').read_text())
            self.assertFalse(socket.parent.exists(), 'temporary socket directory leaked')
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

    def test_changed_inputs_do_not_replace_backing_images(self):
        self.make('all')
        base = self.platform / 'base-image/images' / self.image_subdir / 'base.qcow2'
        base.write_text('existing backing image')
        # Force Make to consider both stages stale without changing timestamps.
        self.make('all', '-W', f'base-image/{self.base_template}', succeeds=False)
        self.assertEqual(base.read_text(), 'existing backing image')
        worker = self.platform / 'buildkite-worker/images' / self.image_subdir / 'worker.qcow2'
        expected = worker.read_text()
        self.make('worker', '-W', 'buildkite-worker/kvm_machine.pkr.hcl', succeeds=False)
        self.assertEqual(worker.read_text(), expected)
        self.assertTrue(Path(str(worker) + '-1').is_file())

class FreeBSDImageStagingTests(ImageStagingChecks, unittest.TestCase):
    platform_name = 'freebsd-kvm'
    image_subdir = 'x86_64'
    base_template = 'freebsd.pkr.hcl'

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


class WindowsImageStagingTests(ImageStagingChecks, unittest.TestCase):
    platform_name = 'windows-kvm'
    image_subdir = ''
    base_template = 'windows_server_2022.pkr.hcl'

    def setUp(self):
        super().setUp()
        # Already-extracted driver fixtures avoid network access in Make tests.
        downloads = self.platform / 'base-image/downloads'
        downloads.mkdir()
        (downloads / 'virtio-win.iso').touch()
        drivers = self.platform / 'base-image/virtio-win'
        drivers.mkdir()
        (drivers / 'virtio-win-guest-tools.exe').touch()

    def test_relative_staging_and_clean_isolation(self):
        self.make('all')
        self.make('all', 'IMAGE_ROOT=generations/01')
        self.check_images(self.platform / 'generations/01')
        self.make('clean', 'IMAGE_ROOT=generations/01')
        self.check_images(self.platform)
        self.assertFalse((self.platform / 'generations/01/base-image/images').exists())
        self.assertFalse((self.platform / 'generations/01/buildkite-worker/images').exists())

    def test_refresh_produces_worker_input_without_modifying_source(self):
        source = self.root / 'old-base.qcow2'
        source.write_text('original base')
        args = ('IMAGE_ROOT=generations/refresh', f'SOURCE_IMAGE={source}')
        self.make('validate-refresh', *args)
        self.make('refresh', *args)
        self.make('worker', *args)
        generation = self.platform / 'generations/refresh'
        self.check_images(generation)
        self.assertEqual((generation / 'base-image/images/base.qcow2').read_text(), str(source))
        self.make('refresh', *args, succeeds=False)
        self.assertEqual(source.read_text(), 'original base')
        self.check_images(generation)

    def test_refresh_requires_an_explicit_existing_source(self):
        self.make('refresh', succeeds=False)
        self.make('validate-refresh', 'SOURCE_IMAGE=missing.qcow2', succeeds=False)


if __name__ == '__main__':
    unittest.main()
