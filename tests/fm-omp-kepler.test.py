"""Behavior tests with real inert children; no OMP is imported or executed."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'bin' / 'omp-kepler' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


controller = load('controller')
boundary = load('fs_boundary')
signer = load('record_signer')


class Filesystem(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        (self.root / 'a.txt').write_text('alpha beta\n')

    def tearDown(self):
        self.temp.cleanup()

    def test_confined_mutations_and_changed_target(self):
        args = {'operation': 'edit', 'path': 'a.txt', 'oldText': 'alpha', 'newText': 'omega'}
        preview = boundary.preview(str(self.root), args)[0]
        (self.root / 'a.txt').write_text('alpha changed\n')
        with self.assertRaises(ValueError):
            boundary.execute(str(self.root), args, preview)
        self.assertEqual((self.root / 'a.txt').read_text(), 'alpha changed\n')
        preview = boundary.preview(str(self.root), args)[0]
        self.assertEqual(boundary.execute(str(self.root), args, preview), 'mutation_applied')
        args = {'operation': 'write', 'path': 'new.txt', 'content': 'new'}
        preview = boundary.preview(str(self.root), args)[0]
        self.assertEqual(boundary.execute(str(self.root), args, preview), 'mutation_applied')
        with self.assertRaises(ValueError):
            boundary.execute(str(self.root), args, preview)

    def test_paths_symlinks_links_fifo_and_bounds(self):
        for path in ('/tmp/foreign', '../foreign', 'x/../a', '.git/config', '.env.local', '.codex/auth.json', 'state/control', 'config/key', 'a//b'):
            with self.subTest(path=path), self.assertRaises((ValueError, OSError)):
                boundary.preview(str(self.root), {'operation': 'read', 'path': path})
        outside = self.root.parent / (self.root.name + '-outside')
        outside.write_text('outside')
        try:
            (self.root / 'symlink').symlink_to(outside)
            os.link(outside, self.root / 'hardlink')
            (self.root / 'alias').symlink_to(self.root, target_is_directory=True)
            os.mkfifo(self.root / 'fifo')
            (self.root / 'big').write_bytes(b'x' * 65537)
            for path in ('symlink', 'hardlink', 'alias/new', 'fifo', 'big'):
                with self.subTest(path=path), self.assertRaises((ValueError, OSError)):
                    boundary.preview(str(self.root), {'operation': 'write', 'path': path, 'content': 'bad'})
            self.assertEqual(outside.read_text(), 'outside')
            self.assertEqual(boundary.grep(str(self.root), '.', 'alpha'), 'a.txt:1:alpha beta')
        finally:
            outside.unlink()


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fm-omp-inert-')
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / 'home'
        self.home.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def run_child(self, body, seconds=2):
        script = self.root / 'inert.py'
        script.write_text(body)
        return controller.supervise([sys.executable, '-I', str(script)], self.root / 'state',
                                    time.time() + seconds, controller.clean_env(self.home))

    def test_continuation_terminal_and_reaped(self):
        record = self.run_child('print(\'{"type":"agent_start"}\',flush=True)\nprint(\'{"type":"agent_end","isTerminal":false}\',flush=True)\nprint(\'{"type":"agent_end","isTerminal":true}\',flush=True)\nprint(\'{"type":"worker_result","task":"inert","stopReason":"stop","text":"inert fixture"}\',flush=True)\n')
        self.assertEqual(record['state'], 'completed')
        self.assertTrue(record['reaped'])
        self.assertGreater(record['sequence'], 2)
        self.assertIsNone(controller.identity(record['pid']))

    def test_quiet_exit_is_failure(self):
        record = self.run_child('pass\n')
        self.assertEqual(record['state'], 'failed')
        self.assertFalse(record['terminalReceipt'])

    def test_stalled_input_cannot_block_watchdog_deadline(self):
        script = self.root / 'inert.py'
        script.write_text('import signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\ntime.sleep(30)\n')
        payload = {'capsuleHash': 'inert', 'padding': 'x' * 100000,
                   'capsule': {'task': 'ATX-2170', 'sourceHashes': {}, 'head': 'inert', 'worktree': str(self.root),
                               'cockpit': 'kepler', 'keplerTaskId': None, 'keplerWorktreeId': None}}
        begin = time.monotonic()
        record = controller.supervise([sys.executable, '-I', str(script)], self.root / 'state',
                                      time.time()+.2, controller.clean_env(self.home), payload=payload)
        self.assertEqual(record['state'], 'expired')
        self.assertTrue(record['reaped'])
        self.assertLess(time.monotonic()-begin, 2)

    def test_wrong_extension_event_is_failure(self):
        record = self.run_child('print(\'{"type":"agent_end","willContinue":false}\',flush=True)\nimport time;time.sleep(2)\n')
        self.assertEqual(record['state'], 'invalid-receipt')
        self.assertTrue(record['reaped'])

    def test_expiry_kills_stalled_event_loop_and_descendants(self):
        child_pid = self.root / 'descendant.pid'
        body = ('import subprocess,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
                f'p=subprocess.Popen(["/bin/sleep","30"]);open({str(child_pid)!r},"w").write(str(p.pid))\n'
                'while True: time.sleep(1)\n')
        begin = time.monotonic()
        record = self.run_child(body, .2)
        self.assertEqual(record['state'], 'expired')
        self.assertTrue(record['reaped'])
        self.assertLess(time.monotonic() - begin, 2)
        descendant = int(child_pid.read_text())
        # A zombie is dead, pending its OS init reaper; never a live helper.
        status = subprocess.run(['ps', '-p', str(descendant), '-o', 'stat='], stdout=subprocess.PIPE).stdout.decode().strip()
        self.assertTrue(not status or status.startswith('Z'))

    def test_controller_sigkill_independent_watchdog_reaps(self):
        script = self.root / 'inert.py'
        script.write_text('import signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\ntime.sleep(30)\n')
        runner = self.root / 'runner.py'
        runner.write_text(f'import sys;sys.path.insert(0,{str(ROOT / "bin" / "omp-kepler")!r})\nimport controller,time\nfrom pathlib import Path\ncontroller.supervise([{sys.executable!r},"-I",{str(script)!r}],{str(self.root / "state")!r},time.time()+20,controller.clean_env(Path({str(self.home)!r})))\n')
        parent = subprocess.Popen([sys.executable, '-I', str(runner)])
        marker = self.root / 'state' / 'receipt.json'
        end = time.monotonic() + 3
        while not marker.exists() and time.monotonic() < end:
            time.sleep(.02)
        self.assertTrue(marker.exists())
        record = json.loads(marker.read_text())
        os.kill(parent.pid, signal.SIGKILL)
        parent.wait(timeout=2)
        while not json.loads(marker.read_text())['reaped'] and time.monotonic() < end:
            time.sleep(.03)
        final = json.loads(marker.read_text())
        self.assertEqual(final['state'], 'controller-lost')
        self.assertTrue(final['reaped'])
        self.assertIsNone(controller.identity(record['pid']))

    def test_interrupt_exact_identity_and_status_reconnect(self):
        runner = self.root / 'runner.py'
        script = self.root / 'inert.py'
        script.write_text('import time\nprint(\'{"type":"agent_start"}\',flush=True)\ntime.sleep(30)\n')
        runner.write_text(f'import sys;sys.path.insert(0,{str(ROOT / "bin" / "omp-kepler")!r})\nimport controller,time\nfrom pathlib import Path\ncontroller.supervise([{sys.executable!r},"-I",{str(script)!r}],{str(self.root / "state")!r},time.time()+20,controller.clean_env(Path({str(self.home)!r})))\n')
        parent = subprocess.Popen([sys.executable, '-I', str(runner)])
        marker = self.root / 'state' / 'receipt.json'
        end = time.monotonic() + 3
        while not marker.exists() and time.monotonic() < end:
            time.sleep(.02)
        record = json.loads(marker.read_text())
        self.assertEqual(controller.identity(record['pid']), record['start'])
        for request, expected in ((b'wrong:interrupt', b'refused'), (record['owner'].encode()+b':interrupt', b'accepted')):
            connection = socket.socket(socket.AF_UNIX)
            connection.connect(str(self.root / 'state' / 'control.sock'))
            connection.sendall(request)
            self.assertEqual(connection.recv(1024), expected)
            connection.close()
        parent.wait(timeout=3)
        final = json.loads(marker.read_text())
        self.assertEqual(final['state'], 'interrupted')
        self.assertTrue(final['reaped'])

    def test_cross_task_worktree_lease_and_failure_cleanup(self):
        lease = self.root / 'leases' / 'same-worktree'
        lease.mkdir(parents=True)
        controller.atomic(lease / 'owner.json', {'owner': 'foreign'})
        with self.assertRaises(FileExistsError):
            controller._supervise(['/bin/sleep', '1'], self.root / 'state', time.time()+2,
                                  controller.clean_env(self.home), lease=lease)
        self.assertEqual(json.loads((lease / 'owner.json').read_text())['owner'], 'foreign')
        (lease / 'owner.json').unlink()
        lease.rmdir()
        with self.assertRaises(FileNotFoundError):
            controller._supervise(['/does-not-exist-inert'], self.root / 'state', time.time()+2,
                                  controller.clean_env(self.home), lease=lease)
        self.assertFalse(lease.exists())
        self.assertFalse((self.root / 'state' / 'control.sock').exists())

    def test_foreign_marker_is_preserved_on_cleanup(self):
        runner = self.root / 'runner.py'
        runner.write_text(f'import sys;sys.path.insert(0,{str(ROOT / "bin" / "omp-kepler")!r})\nimport controller,time\nfrom pathlib import Path\ncontroller.supervise(["/bin/sleep","30"],{str(self.root / "state")!r},time.time()+20,controller.clean_env(Path({str(self.home)!r})))\n')
        parent = subprocess.Popen([sys.executable, '-I', str(runner)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        marker = self.root / 'state' / 'receipt.json'
        end = time.monotonic() + 3
        while not marker.exists() and time.monotonic() < end:
            time.sleep(.02)
        record = json.loads(marker.read_text())
        controller.atomic(marker, {'owner': 'foreign', 'preserve': True})
        parent.wait(timeout=3)
        self.assertEqual(json.loads(marker.read_text()), {'owner': 'foreign', 'preserve': True})
        self.assertIsNone(controller.identity(record['pid']))


class Entry(unittest.TestCase):
    def test_registration_is_fixed_and_does_not_install(self):
        result = subprocess.run(['/bin/bash', str(ROOT / 'bin/fm-omp-kepler.sh'), 'registration', 'ATX-2170'], stdout=subprocess.PIPE, check=True)
        record = json.loads(result.stdout)
        self.assertEqual(record['kind'], 'terminal')
        self.assertEqual(record['args'], ['handoff', 'ATX-2170'])
        self.assertEqual(record['env'], {})
        self.assertTrue(record['command'].startswith('/'))

    def test_default_launch_refuses_without_trusted_host(self):
        # No trusted host is installed in test runs; no SDK can start.
        result = subprocess.run(['/bin/bash', str(ROOT / 'bin/fm-omp-kepler.sh'), 'launch', 'ATX-2170'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')

    def test_fixed_root_handoff_cannot_choose_account_or_command(self):
        host = {'task': 'ATX-2170', 'workerAccount': {'name': 'fm-omp-worker', 'uid': 65533, 'gid': 65533}}
        lookup = lambda name: SimpleNamespace(pw_uid=65533, pw_gid=65533) if name == 'fm-omp-worker' else None
        self.assertEqual(controller.handoff_command(host, 'ATX-2170', lookup),
                         ['/usr/sbin/runuser', '-u', 'fm-omp-worker', '--', '/bin/bash',
                          str(ROOT / 'bin/fm-omp-kepler.sh'), 'launch', 'ATX-2170'])
        for record in ({}, {'name': 'root', 'uid': 0, 'gid': 0}, {'name': 'foreign', 'uid': 65533, 'gid': 65533},
                       {'name': 'fm-omp-worker', 'uid': 1, 'gid': 1}):
            with self.assertRaises(ValueError):
                controller.handoff_command({**host, 'workerAccount': record}, 'ATX-2170', lookup)
        with self.assertRaises(ValueError):
            controller.handoff_command(host, 'ATX-2171', lookup)


class OwnerRecords(unittest.TestCase):
    def test_publish_replaces_link_without_following_and_refuses_linked_parent(self):
        with tempfile.TemporaryDirectory(prefix='fm-owner-publish-fixture-') as directory:
            root = Path(directory).resolve()
            outside = root / 'outside'
            outside.write_text('preserve')
            target = root / 'receipt.json'
            target.symlink_to(outside)
            signer.publish(target, {'fixture': True}, 0o644)
            self.assertEqual(outside.read_text(), 'preserve')
            self.assertEqual(json.loads(target.read_text()), {'fixture': True})
            (root / 'alias').symlink_to(root, target_is_directory=True)
            with self.assertRaises(OSError):
                signer.publish(root / 'alias' / 'other.json', {'fixture': True}, 0o644)

    def test_mutation_producer_binds_exact_preview_and_credit(self):
        with tempfile.TemporaryDirectory(prefix='fm-owner-fixture-') as directory:
            root = str(Path(directory).resolve())
            args = {'operation': 'write', 'path': 'file.txt', 'content': 'fixture'}
            capsule = {'task': 'ATX-2170', 'role': 'crew', 'worktree': root, 'deadline': 200,
                       'model': {'provider': 'fixture', 'id': 'fixture'}}
            request = {'version': 1, 'task': 'ATX-2170', 'capsuleHash': 'fixture-hash', 'operation': 'write',
                       'arguments': args, 'preview': boundary.preview(root, args)[0], 'expiresAt': 130}
            signer.bind_mutation(request, capsule, 'fixture-hash', 100)
            with self.assertRaises(ValueError):
                signer.bind_mutation(request, capsule, 'foreign-hash', 100)
            (Path(root) / 'file.txt').write_text('changed')
            with self.assertRaises(ValueError):
                signer.bind_mutation(request, capsule, 'fixture-hash', 100)
            credit = {'version': 1, 'kind': 'verified-provider-credit', 'task': 'ATX-2170', 'capsuleHash': 'fixture-hash',
                      'provider': 'fixture', 'modelId': 'fixture', 'accountEvidenceRef': 'inert-account', 'usageEvidenceRef': 'inert-usage',
                      'included': True, 'overage': 0, 'observedAt': 99, 'validUntil': 130}
            signer.bind_credit(credit, capsule, 'fixture-hash', 100)
            for bad in ({**credit, 'overage': 1}, {**credit, 'observedAt': 1}, {**credit, 'provider': 'foreign'}):
                with self.assertRaises(ValueError):
                    signer.bind_credit(bad, capsule, 'fixture-hash', 100)

    def test_fixture_openssl_sign_verify_and_tamper(self):
        version = subprocess.run(['/usr/bin/openssl', 'version'], stdout=subprocess.PIPE, check=True).stdout
        if not version.startswith(b'OpenSSL 3'):
            self.skipTest('native Ed25519 producer proof requires OpenSSL 3; Linux proof must run this case')
        with tempfile.TemporaryDirectory(prefix='fm-owner-ed25519-fixture-') as directory:
            private, public = Path(directory) / 'fixture.key', Path(directory) / 'fixture.pub'
            subprocess.run(['/usr/bin/openssl', 'genpkey', '-algorithm', 'Ed25519', '-out', str(private)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            os.chmod(private, 0o600)
            subprocess.run(['/usr/bin/openssl', 'pkey', '-in', str(private), '-pubout', '-out', str(public)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            envelope = signer.sign_record({'inertFixture': True}, private)
            self.assertEqual(controller.verify_envelope(envelope, public), {'inertFixture': True})
            envelope['payload']['inertFixture'] = False
            with self.assertRaises(ValueError):
                controller.verify_envelope(envelope, public)


if __name__ == '__main__':
    unittest.main(verbosity=2)
