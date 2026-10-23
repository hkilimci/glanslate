"""Exercise release orchestration without signing keys, Apple uploads, or publishing.

Run on macOS: python3 -m unittest discover -s scripts/tests -v
"""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


FAKE_TOOL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import plistlib
import sys

tool, args = Path(sys.argv[0]).name, sys.argv[1:]
root = Path(os.environ['RELEASE_TEST_ROOT'])
with (root / 'events.jsonl').open('a') as events:
    events.write(json.dumps({'tool': tool, 'args': args}) + '\n')

if tool == 'security':
    print('  1) ' + 'B' * 40 + ' "Developer ID Application: Other (ZZZZZZZZZZ)"')
    if not os.environ.get('NO_IDENTITY'):
        print('  2) ' + 'A' * 40 + ' "Developer ID Application: Test (J2WJMC3K74)"')
elif tool == 'xcrun':
    if args[:2] == ['notarytool', 'history']:
        if os.environ.get('BAD_CREDENTIALS'):
            sys.exit(1)
    elif args[:2] == ['notarytool', 'submit']:
        kind = 'app' if Path(args[2]).name == 'Glanslate-app-notarization.dmg' else 'dmg'
        status = 'Invalid' if os.environ.get('REJECT_ARTIFACT') == kind else 'Accepted'
        sys.stdout.buffer.write(plistlib.dumps({'status': status, 'id': 'test-' + kind}))
    elif args[:2] == ['stapler', 'staple'] and args[2].endswith('.dmg'):
        if os.environ.get('FAIL_STAPLE_DMG'):
            sys.exit(65)
elif tool == 'xcodebuild':
    if '-showBuildSettings' in args:
        print('    MARKETING_VERSION = 1.0.0')
        print('    GLANSLATE_UPDATE_REPOSITORY = example/glanslate')
    elif 'archive' in args:
        Path(args[args.index('-archivePath') + 1]).mkdir(parents=True)
    elif '-exportArchive' in args:
        export = Path(args[args.index('-exportPath') + 1])
        contents = export / 'Glanslate.app' / 'Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': '1.0.0',
            'CFBundleIdentifier': 'com.azrapps.glanslate',
            'GlanslateUpdateRepository': 'example/glanslate',
        }))
elif tool in ('ditto', 'hdiutil'):
    Path(args[-1]).write_bytes(b'test archive')
elif tool == 'git':
    if 'rev-parse' in args:
        print('c' * 40)
elif tool == 'gh':
    if args[:2] == ['release', 'view'] or (args[0] == 'api' and '/commits/v' in args[1]):
        sys.exit(1)
elif tool == 'spctl' and args[-1].endswith('.dmg'):
    if os.environ.get('FAIL_GATEKEEPER_DMG'):
        sys.exit(3)
'''


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='glanslate release ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / 'scripts'
        scripts.mkdir()
        source = Path(__file__).resolve().parents[1]
        for name in ('release.sh', 'make-dmg.sh'):
            shutil.copy2(source / name, scripts / name)
        (self.root / 'Glanslate.xcodeproj').mkdir()
        tools = self.root / 'bin'
        tools.mkdir()
        fake = tools / 'fake-tool'
        fake.write_text(FAKE_TOOL)
        fake.chmod(0o755)
        for name in ('security', 'xcrun', 'xcodebuild', 'codesign', 'spctl',
                     'ditto', 'hdiutil', 'git', 'gh'):
            (tools / name).symlink_to(fake)
        self.env = os.environ.copy()
        # Do not let the developer's release options or test switches leak in.
        for key in ('DMG_OUTPUT', 'RELEASE_NOTES', 'NO_IDENTITY', 'BAD_CREDENTIALS',
                    'REJECT_ARTIFACT', 'FAIL_STAPLE_DMG', 'FAIL_GATEKEEPER_DMG'):
            self.env.pop(key, None)
        self.env.update(
            PATH=str(tools) + os.pathsep + self.env['PATH'],
            RELEASE_TEST_ROOT=str(self.root),
            GLANSLATE_DEVELOPMENT_TEAM='J2WJMC3K74',
            NOTARY_PROFILE='test-profile',
            PUBLISH='1',
        )

    def release(self, **env):
        result = subprocess.run(
            ['bash', str(self.root / 'scripts/release.sh')],
            cwd=self.root, env={**self.env, **env}, capture_output=True, text=True,
        )
        events = self.root / 'events.jsonl'
        self.events = [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
        return result

    def matching(self, tool, prefix=(), suffix=None):
        return [i for i, event in enumerate(self.events)
                if event['tool'] == tool
                and event['args'][:len(prefix)] == list(prefix)
                and (suffix is None or event['args'][-1].endswith(suffix))]

    def assert_no_publish(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.matching('gh', ('release', 'create')))

    def test_verified_artifacts_are_published_in_order(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        app_staple = self.matching('xcrun', ('stapler', 'staple'), '.app')[0]
        app_create, dmg_create = self.matching('hdiutil', ('create',))
        app_sign, dmg_sign = self.matching('codesign', ('--sign',))
        app_submit, dmg_submit = self.matching('xcrun', ('notarytool', 'submit'))
        dmg_staple = self.matching('xcrun', ('stapler', 'staple'), '.dmg')[0]
        dmg_validate = self.matching('xcrun', ('stapler', 'validate'), '.dmg')[0]
        dmg_verify = self.matching('codesign', ('--verify',), '.dmg')[0]
        gatekeeper = self.matching('spctl', suffix='.dmg')[0]
        publish = self.matching('gh', ('release', 'create'))[0]
        order = [app_create, app_sign, app_submit, app_staple, dmg_create, dmg_sign, dmg_submit,
                 dmg_staple, dmg_validate, dmg_verify, gatekeeper, publish]
        self.assertEqual(order, sorted(order))
        self.assertEqual(self.events[dmg_sign]['args'][1], 'A' * 40)
        self.assertIn('--timestamp', self.events[dmg_sign]['args'])
        self.assertIn('com.azrapps.glanslate.dmg', self.events[dmg_sign]['args'])
        self.assertFalse(self.matching('ditto'))
        self.assertFalse(any(arg.lower().endswith('.zip') for event in self.events for arg in event['args']))
        self.assertFalse((self.root / 'build/Glanslate-app-notarization.dmg').exists())
        self.assertTrue((self.root / 'build/Glanslate-1.0.0.dmg').exists())
        assets = [arg for arg in self.events[publish]['args'] if arg.endswith(('.dmg', '.zip'))]
        self.assertEqual(assets, [str(self.root / 'build/Glanslate-1.0.0.dmg')])
        archive = next(e for e in self.events if e['tool'] == 'xcodebuild' and 'archive' in e['args'])
        self.assertIn('CODE_SIGN_IDENTITY=' + 'A' * 40, archive['args'])
        for kind in ('app', 'dmg'):
            with (self.root / f'build/Glanslate-{kind}-notarization.plist').open('rb') as f:
                self.assertEqual(plistlib.load(f)['status'], 'Accepted')

    def test_missing_profile_stops_before_build(self):
        self.env.pop('NOTARY_PROFILE')
        self.assert_no_publish(self.release(PUBLISH='0'))
        self.assertFalse(self.events)

    def test_non_dmg_output_stops_before_build(self):
        result = self.release(DMG_OUTPUT=str(self.root / 'Glanslate.zip'))
        self.assert_no_publish(result)
        self.assertIn('DMG_OUTPUT must end in .dmg', result.stderr)
        self.assertFalse(self.events)

    def test_custom_dmg_name_is_the_only_published_asset(self):
        output = str(self.root / 'custom release.dmg')
        result = self.release(DMG_OUTPUT=output)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        publish = self.events[self.matching('gh', ('release', 'create'))[0]]
        self.assertEqual([arg for arg in publish['args'] if arg.endswith('.dmg')], [output])
        self.assertTrue(Path(output).exists())

    def test_packaging_without_publishing_still_notarizes_dmg(self):
        result = self.release(PUBLISH='0')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.matching('xcrun', ('stapler', 'validate'), '.dmg'))
        self.assertTrue(self.matching('spctl', suffix='.dmg'))
        self.assertFalse(self.matching('gh'))

    def test_missing_team_certificate_stops_before_build(self):
        self.assert_no_publish(self.release(NO_IDENTITY='1'))
        self.assertFalse(self.matching('xcodebuild'))

    def test_invalid_credentials_stop_before_build(self):
        self.assert_no_publish(self.release(BAD_CREDENTIALS='1'))
        self.assertFalse(self.matching('xcodebuild'))

    def test_rejected_app_stops_before_final_packaging(self):
        result = self.release(REJECT_ARTIFACT='app')
        self.assert_no_publish(result)
        self.assertIn('was Invalid', result.stderr)
        self.assertEqual(len(self.matching('hdiutil')), 1)
        self.assertFalse(self.matching('xcrun', ('stapler', 'staple')))

    def test_rejected_dmg_is_not_stapled_or_published(self):
        result = self.release(REJECT_ARTIFACT='dmg')
        self.assert_no_publish(result)
        self.assertIn('was Invalid', result.stderr)
        self.assertFalse(self.matching('xcrun', ('stapler', 'staple'), '.dmg'))

    def test_failed_stapling_stops_publishing(self):
        self.assert_no_publish(self.release(FAIL_STAPLE_DMG='1'))

    def test_gatekeeper_rejection_stops_publishing(self):
        self.assert_no_publish(self.release(FAIL_GATEKEEPER_DMG='1'))


if __name__ == '__main__':
    unittest.main()
