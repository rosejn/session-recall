#!/usr/bin/env python3
"""Regression checks for profile identity, window matching and daemon fallback."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sqlite3
from datetime import datetime, timedelta, timezone
import unittest
import runpy

ROOT = Path(__file__).resolve().parents[1]


class RestoreTests(unittest.TestCase):
    def test_empty_shutdown_capture_preserves_checkpoint(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            state = home / 'state'
            saved = state / 'snapshots/auto-before-shutdown'
            saved.mkdir(parents=True)
            (saved / 'snapshot.json').write_text('{"windows": [{"class": "ghostty"}]}')
            for link in ('latest', 'last-auto'):
                (state / link).symlink_to(saved)
            binaries = home / 'bin'
            binaries.mkdir()
            for name, body in {'hyprctl': 'case "$*" in *activewindow*) echo "{}";; *) echo "[]";; esac', 'herdr': 'exit 1',
                               'tmux': 'exit 1'}.items():
                script = binaries / name
                script.write_text('#!/bin/sh\n' + body + '\n')
                script.chmod(0o755)
            result = subprocess.run(['bash', str(ROOT / 'bin/recall-capture'), '--auto'],
                env=dict(os.environ, HOME=tmp, RECALL_STATE_DIR=str(state),
                         PATH=str(binaries) + ':' + os.environ['PATH']),
                capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            for link in ('latest', 'last-auto'):
                self.assertEqual((state / link).resolve(), saved)
            self.assertEqual(list((state / 'snapshots').iterdir()), [saved])

    def test_codex_hook_routes_by_tui_not_inherited_pane(self):
        route = runpy.run_path(str(ROOT / 'bin/recall-codex-session-hook'))['matching_panes']
        panes = [{'pane_id': 'w1:p1', 'agent': 'codex'},
                 {'pane_id': 'w2:p1', 'agent': 'codex'}]
        processes = {'w1:p1': [{'argv': ['/bin/codex', 'resume', 'mobile']}],
                     'w2:p1': [{'argv': ['/bin/codex', 'resume', 'kerml']}]}
        self.assertEqual(route(panes, processes, 'kerml'), ['w2:p1'])
        self.assertEqual(route(panes, processes, 'desktop-session'), [])
        # An embedded/shared server must not be mistaken for the terminal UI.
        processes['w1:p1'] = [{'argv': ['/bin/codex', 'app-server']}]
        self.assertEqual(route(panes, processes, 'mobile'), [])

    def test_codex_title_match_is_unique_and_ignores_subagents(self):
        with tempfile.TemporaryDirectory() as tmp:
            codex = Path(tmp) / '.codex'
            codex.mkdir()
            sid = '11111111-1111-4111-8111-111111111111'
            rollout = codex / 'root.jsonl'
            rollout.write_text(json.dumps({'type': 'session_meta', 'payload': {
                'id': sid, 'source': 'cli', 'thread_source': 'user'}}) + '\n')
            cwd = "/project/owner's repo"
            db = sqlite3.connect(codex / 'state_5.sqlite')
            db.execute('CREATE TABLE threads (id, rollout_path, cwd, name, title, archived, thread_source)')
            db.execute('INSERT INTO threads VALUES (?, ?, ?, ?, ?, 0, ?)',
                (sid, str(rollout), cwd, "User's session", '', 'user'))
            db.commit()
            def match():
                return subprocess.run(['bash', '-c',
                    'source "$1"; match_codex_by_title "$2" "$3" && printf "%s" "$MATCHED_ID"',
                    'test', str(ROOT / 'bin/recall-lib'), cwd, "User's session | repo"],
                    env=dict(os.environ, HOME=tmp), capture_output=True, text=True)
            self.assertEqual(match().stdout, sid)
            db.execute('INSERT INTO threads SELECT * FROM threads')
            db.commit()
            self.assertNotEqual(match().returncode, 0)
            db.execute('DELETE FROM threads WHERE rowid = 2')
            db.commit()
            rollout.write_text(json.dumps({'type': 'session_meta', 'payload': {
                'id': sid, 'source': {'subagent': {'thread_spawn': {}}}}}) + '\n')
            self.assertNotEqual(match().returncode, 0)
            db.close()

    def test_codex_launch_match_skips_closer_subagent(self):
        with tempfile.TemporaryDirectory() as tmp:
            now = datetime.now(timezone.utc)
            day = Path(tmp) / '.codex/sessions' / now.astimezone().strftime('%Y/%m/%d')
            day.mkdir(parents=True)
            root_id = '11111111-1111-4111-8111-111111111111'
            for sid, seconds, source in ((root_id, 60, 'cli'),
                    ('22222222-2222-4222-8222-222222222222', 0, {'subagent': {}})):
                (day / f'rollout-test-{sid}.jsonl').write_text(json.dumps({
                    'type': 'session_meta', 'payload': {'id': sid, 'source': source,
                    'cwd': '/project', 'timestamp': (now - timedelta(seconds=seconds)).isoformat()}}) + '\n')
            result = subprocess.check_output(['bash', '-c',
                'source "$1"; match_codex_by_launch "$2" /project && printf "%s" "$MATCHED_ID"',
                'test', str(ROOT / 'bin/recall-lib'), str(os.getpid())],
                env=dict(os.environ, HOME=tmp), text=True)
            self.assertEqual(result, root_id)

    def test_profile_from_session_title_and_saved_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'google-chrome'
            root.mkdir()
            (root / 'Local State').write_text(json.dumps({'profile': {
                'info_cache': {'Default': {}, 'Profile 1': {}},
                'last_active_profiles': ['Profile 1']}}))
            sessions = root / 'Default/Sessions'
            sessions.mkdir(parents=True)
            (sessions / 'Session_1').write_bytes('Project · α'.encode('utf-16-le'))
            env = dict(os.environ, XDG_CONFIG_HOME=tmp)
            def profile(window):
                return json.loads(subprocess.check_output([
                    str(ROOT / 'bin/recall-browser-profile'), json.dumps(window)], env=env))['browser']
            self.assertEqual(profile({'class': 'google-chrome', 'title': 'Project · α - Google Chrome'})['profiles'], ['Default'])
            self.assertEqual(profile({'class': 'google-chrome', 'title': 'unknown'})['profiles'], ['Profile 1'])
            self.assertEqual(profile({'browser': {'profiles': ['Default']}})['profiles'], ['Default'])

    def test_browser_launch_requests_crash_restore_and_profile(self):
        window = json.dumps({'class': 'google-chrome', 'browser': {'profiles': ['Profile 1']}})
        result = subprocess.check_output(['bash', '-c',
            'source "$1/bin/recall-handlers"; source "$1/apps/chromium.sh"; app_command "$2"',
            'test', str(ROOT), window], text=True)
        # Decode the generated shell command without launching a browser.
        import shlex
        args = shlex.split(shlex.split(result)[2])
        self.assertIn('--profile-directory=Profile 1', args)
        self.assertIn('--restore-last-session', args)
        self.assertIn('--hide-crash-restore-bubble', args)

    def test_reversed_browser_arrival_matches_title(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            clients = [dict(address='0x2', title='Second', **{'class': 'google-chrome'}),
                       dict(address='0x1', title='First', **{'class': 'google-chrome'})]
            windows = [dict(c, workspace={'id': n, 'name': str(n)}, at=[0, 0], size=[100, 100],
                            floating=False, fullscreen=0, focused=False, launch={'tier': 'known'})
                       for n, c in enumerate(reversed(clients), 1)]
            snapshot = dict(name='fixture', createdAt='now', monitorTopology='', windows=windows,
                            workspaces=[], terminal={})
            (path / 'snapshot.json').write_text(json.dumps(snapshot))
            (path / 'format-version').write_text('1')
            mock = path / 'hyprctl'
            mock.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(' + repr(clients) + ' if sys.argv[-1]=="clients" else []))\n')
            mock.chmod(0o755)
            result = subprocess.check_output([str(ROOT / 'bin/recall-restore'), tmp, '--dry-run', '--no-agents', '--no-geometry'],
                env=dict(os.environ, PATH=tmp + ':' + os.environ['PATH'], RECALL_STATE_DIR=tmp), text=True)
            self.assertIn('window_to_workspace 0x1 1', result)
            self.assertIn('window_to_workspace 0x2 2', result)
            self.assertNotIn('would launch:', result)

    def test_codex_resume_from_bash_and_fish(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / 'codex'
            exe.write_text('#!/bin/bash\n[[ "$1" == app-server ]] && exit "$DAEMON_EXIT"\nprintf "%s\\n" "$@"\n')
            exe.chmod(0o755)
            command = subprocess.check_output(['bash', '-c',
                'source "$1"; agent_resume_command /tmp session-id argv',
                'test', str(ROOT / 'agents/codex.sh')],
                env=dict(os.environ, PATH=tmp + ':' + os.environ['PATH']), text=True)
            for shell in ('bash', 'fish'):
                for daemon_exit in ('0', '1'):
                    with self.subTest(shell=shell, daemon_exit=daemon_exit):
                        result = subprocess.check_output([shell, '-c', command],
                            env=dict(os.environ, DAEMON_EXIT=daemon_exit), text=True)
                        expected = ['resume', 'session-id']
                        if daemon_exit == '1':
                            expected.insert(0, '--no-daemon')
                        self.assertEqual(result.splitlines(), expected)


if __name__ == '__main__':
    unittest.main()
