"""Run a generated process-compose file the way its callers do: process-compose
itself, from the project directory, with go-task building each process first."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
RUNTIME = ROOT / 'plugins/bayt/runtime'

SERVER = {
    'expose': {'http': {'port': 8000, 'env': 'PORT'}},
    'healthcheck': {'url': 'http://127.0.0.1:8000/', 'interval': '1s', 'start_period': '10s'},
    'entrypoint': {'do': 'echo $$ > server.pid; exec python3 -m http.server "$PORT" --bind 127.0.0.1', 'shell': 'sh'},
    # The http template's probe binary is copied into an image; this one is never built.
    'dockerfile': {'from': {'name': 'python:3'}},
}


class ProcessCompose(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.nu = subprocess.check_output(['nu', '-c', '$nu.current-exe'], text=True).strip()
        # `mise exec` installs a missing tool, where `mise where` only reports one.
        cls.task, cls.pc = (subprocess.check_output(
            ['mise', 'exec', tool, '--', 'which', name], text=True,
            env=dict(os.environ, MISE_LOCKED='0'), cwd=ROOT).strip()
            for tool, name in [('github:go-task/task@v3.49.1', 'task'),
                               ('github:F1bonacc1/process-compose@v1.122.0', 'process-compose')])

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='bayt-process-compose-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.project = self.base / 'project'
        self.project.mkdir()
        (self.project / 'input.txt').write_text('before\n')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        launcher = self.bin / 'bayt'
        launcher.write_text(f'#!/bin/sh\nexec {shlex.quote(self.nu)} {shlex.quote(str(RUNTIME / "bayt.nu"))} "$@"\n')
        launcher.chmod(0o755)
        self.env = dict(os.environ,
                        PATH=f'{self.bin}:{Path(self.task).parent}:{Path(self.nu).parent}:' + os.environ['PATH'],
                        BAYT_CACHE_DIR=str(self.base / 'cache'), MISE_LOCKED='0')

    def generate(self, check, after=None, server=SERVER):
        targets = {
            'server': server,
            # Its build copies the input the check then reads.
            'integrate': {'taskfile': {}, 'srcs': {'globs': ['input.txt']},
                          'cmd': {'stage': {'do': 'cp input.txt staged.txt'}}, 'entrypoint': {
                'do': check, 'shell': 'sh',
                'env': {'SERVER_URL': 'http://server:8000/input.txt'},
                'after': after if after is not None else {'server': 'healthy'},
            }},
        }
        project = {'name': 'fixture', 'dir': '', 'activate': '', 'targets': targets}
        source = self.base / 'fixture.cue'
        source.write_text('''package fixture
import b "bonisoft.org/plugins/bayt/core:bayt"
p: b.#project & ''' + json.dumps(project) + '''
p: targets: server: b.healthcheck.http
out: {
 manifests: (b.#manifestGen & {project:p, depManifests:{}}).files
 taskfiles: (b.#taskfileGen & {project:p, depManifests:{}}).files
 root: (b.#taskfileGen & {project:p, depManifests:{}}).root
 bayt: (b.#taskfileGen & {project:p, depManifests:{}}).bayt_root
 processes: (b.#processComposeGen & {project:p, depManifests:{}}).file
}
''')
        data = json.loads(subprocess.check_output(
            ['mise', 'tool-stub', str(RUNTIME / 'cue.toml'), 'export', str(source), '-e', 'out'],
            cwd=ROOT, text=True, env=dict(os.environ, MISE_LOCKED='0')))
        folder = self.project / '.bayt'
        folder.mkdir(exist_ok=True)
        for name, manifest in data['manifests'].items():
            (folder / f'bayt.{name}.json').write_text(json.dumps(manifest))
        for name, taskfile in data['taskfiles'].items():
            (folder / f'Taskfile.{name}.yaml').write_text(json.dumps(taskfile))
        (folder / 'Taskfile.bayt.yml').write_text(json.dumps(data['bayt']))
        (folder / 'Taskfile.yml').write_text(json.dumps(data['root']))
        (folder / 'process-compose.yaml').write_text(json.dumps(data['processes']))
        (self.project / 'Taskfile.yml').write_text(json.dumps({
            'version': '3', 'includes': {'bayt': {'taskfile': './.bayt/Taskfile.bayt.yml', 'dir': '.'}}}))
        return data['processes']

    def run_integrate(self, **env):
        return subprocess.run([self.pc, '--no-server', '-f', '.bayt/process-compose.yaml', 'run', 'integrate'],
                              cwd=self.project, env=dict(self.env, **env), text=True, capture_output=True,
                              stdin=subprocess.DEVNULL, timeout=120)

    FETCH = ('python3 -c "import os, urllib.request; open(\'result.txt\', \'wb\').write(urllib.request.urlopen(os.environ[\'SERVER_URL\']).read())"'
             ' && echo "$SERVER_URL" > url.txt')

    def test_default_port_reaches_the_peer_and_stops_the_stack(self):
        processes = self.generate(self.FETCH + ' && cmp staged.txt input.txt')
        default = re.search(r'SERVER_HTTP_PORT:-(\d+)', json.dumps(processes)).group(1)
        result = self.run_integrate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.project / 'result.txt').read_text(), 'before\n')
        self.assertIn(f'127.0.0.1:{default}/', (self.project / 'url.txt').read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(int((self.project / 'server.pid').read_text()), 0)

    # A caller moves the stack by setting the port variables before load.
    def test_port_variable_moves_the_stack(self):
        self.generate(self.FETCH)
        result = self.run_integrate(SERVER_HTTP_PORT='18731')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('127.0.0.1:18731/', (self.project / 'url.txt').read_text())

    def test_process_failure_is_the_exit_code(self):
        self.generate('exit 7')
        self.assertEqual(self.run_integrate().returncode, 7)

    # process-compose exits 0 when the target never ran because a dependency
    # died, so a stack that cannot start would pass its check.
    def test_dependency_failure_fails_the_run(self):
        broken = dict(SERVER, entrypoint={'do': 'exit 3', 'shell': 'sh'})
        self.generate('echo ran > result.txt', server=broken)
        result = self.run_integrate()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.project / 'result.txt').exists())

    def test_build_failure_fails_the_run(self):
        (self.project / 'input.txt').unlink()
        self.generate('echo ran > result.txt')
        result = self.run_integrate()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.project / 'result.txt').exists())


if __name__ == '__main__':
    unittest.main()
