"""The generated http200 backends agree on status, redirects and deadlines."""
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
RUNTIME = ROOT / 'plugins/bayt/runtime'
CERTS = Path(__file__).parent / 'fixtures/http200'
CONTAINERS = '--containers' in sys.argv
if CONTAINERS:
    sys.argv.remove('--containers')


def checked(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.seen.append((self.command, self.path, self.headers.get('X-Health-Token')))
        path = self.path
        if path == '/slow-headers':
            time.sleep(2)
        status = 204 if path == '/204' else 200
        if path in ['/redirect', '/redirect204', '/loop']:
            status = 302
        if path == '/auth' and self.headers.get('X-Health-Token') != 'Bearer a:$! token':
            status = 403
        self.send_response(status)
        if status == 302:
            self.send_header('Location', {'/redirect': '/200', '/redirect204': '/204', '/loop': '/loop'}[path])
        self.send_header('Content-Length', '0' if path != '/slow-body' else '100')
        self.end_headers()
        if path == '/slow-body':
            time.sleep(2)

    def log_message(self, *args):
        pass


class Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='bayt http200 ', dir=ROOT.parent)
        cls.folder = Path(cls.tmp.name)
        cls.env = dict(os.environ, MISE_TRUSTED_CONFIG_PATHS=os.pathsep.join([str(ROOT), str(RUNTIME), str(ROOT / 'plugins/sayt')]))
        cls.servers = []
        for encrypted in [False, True]:
            server = http.server.ThreadingHTTPServer(('0.0.0.0', 0), Handler)
            server.seen = []
            if encrypted:
                ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                ctx.load_cert_chain(CERTS / 'cert.pem', CERTS / 'key.pem')
                server.socket = ctx.wrap_socket(server.socket, server_side=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            cls.servers.append(server)
        checked(['mise', 'tool-stub', str(ROOT / 'plugins/sayt/process-compose.toml'), 'version'], cwd=ROOT, env=cls.env)
        if CONTAINERS:
            cls.image = f'bayt-http200-test:{os.getpid()}'
            emitted = cls.generate('/200', False, {})
            (cls.folder / 'Dockerfile').write_text('# syntax=' + emitted['frontend'] + '\n' + emitted['docker'])
            scaffolding = cls.folder / '.bayt'
            scaffolding.mkdir()
            for name in ['Taskfile.yml', 'Taskfile.bayt.yml', 'bayt.srv.json']:
                (scaffolding / name).write_text('{}')
            builder = checked(['docker', 'context', 'show']).stdout.strip()
            checked(['docker', 'buildx', 'build', '--builder', builder, '--load', '--target', 'srv', '-t', cls.image, str(cls.folder)])

    @classmethod
    def tearDownClass(cls):
        for server in cls.servers:
            server.shutdown()
            server.server_close()
        if CONTAINERS:
            checked(['docker', 'image', 'rm', cls.image])
        cls.tmp.cleanup()

    @classmethod
    def generate(cls, path, encrypted, headers, overrides=None):
        port = cls.servers[int(encrypted)].server_port
        hc = {'port': port, 'path': path, 'scheme': 'https' if encrypted else 'http', 'headers': headers, 'timeout': '1s', 'retries': 1, 'start_period': '0s'}
        hc.update(overrides or {})
        project = {'name': 'http200', 'dir': '', 'activate': '', 'targets': {
            'srv': {'dockerfile': {'from': None}, 'healthcheck': hc, 'entrypoint': {'do': 'server'}, 'process-compose': {'readiness_probe': {'period_seconds': 1}}},
            'done': {'entrypoint': {'do': 'done', 'after': {'srv': 'healthy'}}},
        }}
        source = cls.folder / 'fixture.cue'
        source.write_text('''package fixture
import b "bonisoft.org/plugins/bayt/core:bayt"
p: b.#project & ''' + json.dumps(project) + '''
p: targets: srv: b.healthcheck.http200
out: {
 frontend: b.#buildkitSyntax
 process: (b.#processComposeGen & {project:p, depManifests:{}}).file
 docker: (b.#dockerComposeGen & {project:p, depManifests:{}}).dockerfiles.srv
 compose: (b.#dockerComposeGen & {project:p, depManifests:{}}).compose.files.srv
 command: p.targets.srv.dockerfile.healthcheck.test
}
''')
        result = checked(['mise', 'tool-stub', str(RUNTIME / 'cue.toml'), 'export', str(source), '-e', 'out'], cwd=ROOT, env=cls.env)
        return json.loads(result.stdout)

    def check(self, path, expected, encrypted=False, trusted=False, headers=None):
        emitted = self.generate(path, encrypted, headers or {})
        env = dict(self.env)
        env.pop('SSL_CERT_FILE', None)
        env.pop('SSL_CERT_DIR', None)
        if trusted:
            env['SSL_CERT_FILE'] = str(CERTS / 'cert.pem')
        if CONTAINERS:
            command = emitted['command'][1:]
            command[-1] = command[-1].replace('127.0.0.1', 'host.docker.internal')
            args = ['docker', 'run', '--rm', '--add-host', 'host.docker.internal:host-gateway']
            if trusted:
                args += ['-v', f'{CERTS.resolve()}:/certs:ro', '-e', 'SSL_CERT_FILE=/certs/cert.pem']
            args += ['--entrypoint', command[0], self.image, *command[1:]]
        else:
            config = emitted['process']
            self.assertNotIn('bayt:httpcheck', config['processes'])
            self.assertIn('http_get', config['processes']['srv']['readiness_probe'])
            config['processes']['srv']['entrypoint'] = [Path(sys.executable).as_posix(), '-c', 'import time; time.sleep(30)']
            config['processes']['done']['entrypoint'] = [Path(sys.executable).as_posix(), '-c', 'pass']
            file = self.folder / 'process-compose.json'
            file.write_text(json.dumps(config))
            args = ['mise', 'tool-stub', str(ROOT / 'plugins/sayt/process-compose.toml'), '--no-server', '-f', str(file), 'run', 'done']
        result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=20)
        self.assertNotIn('Failed to parse', result.stdout + result.stderr)
        self.assertEqual(result.returncode == 0, expected, result.stdout + result.stderr)
        self.assertTrue(all(method == 'GET' for method, _, _ in self.servers[int(encrypted)].seen))

    def test_schema_rejects_unrepresentable_checks(self):
        for overrides in [{'timeout': '200ms'}, {'status': 204}, {'url': 'http://elsewhere/'},
                          {'headers': {'X-A': '1', 'x-a': '2'}},
                          {'headers': {'Host': 'elsewhere'}},
                          {'headers': {'Authorization': 'secret'}},
                          {'headers': {'X-A': 'a\r\nInjected: yes'}}]:
            with self.subTest(overrides=overrides), self.assertRaises(RuntimeError):
                self.generate('/200', False, {}, overrides)

    def test_200(self):
        self.check('/200', True)

    def test_204_is_not_healthy(self):
        self.check('/204', False)

    def test_final_status_after_redirect(self):
        self.check('/redirect', True)
        self.check('/redirect204', False)

    def test_redirect_loop_fails(self):
        self.check('/loop', False)

    def test_deadline_includes_waiting_for_headers(self):
        self.check('/slow-headers', False)

    def test_body_is_not_part_of_health(self):
        self.check('/slow-body', True)

    def test_headers_remain_data(self):
        self.check('/auth', True, headers={'X-Health-Token': 'Bearer a:$! token'})

    def test_untrusted_tls_fails(self):
        self.check('/200', False, encrypted=True)

    @unittest.skipIf(sys.platform != 'linux' and not CONTAINERS, 'Go uses the OS certificate store here, not SSL_CERT_FILE')
    def test_trusted_tls(self):
        self.check('/200', True, encrypted=True, trusted=True)

    @unittest.skipUnless(CONTAINERS, 'container configuration requires Docker')
    def test_container_command_survives_compose_interpolation(self):
        emitted = self.generate('/200', False, {'X-Health-Token': '${SECRET}:$! token'})
        file = self.folder / 'compose.json'
        config = emitted['compose']
        service = config['services']['http200-srv']
        service.pop('build', None)
        service['image'] = self.image
        file.write_text(json.dumps(config))
        compose = ['docker', 'compose', '-p', f'http200-test-{os.getpid()}', '-f', str(file)]
        try:
            checked([*compose, 'create', '--no-build'], cwd=self.folder, env=self.env)
            container = checked([*compose, 'ps', '-aq'], cwd=self.folder, env=self.env).stdout.strip()
            result = checked(['docker', 'inspect', '--format', '{{json .Config.Healthcheck.Test}}', container])
            self.assertEqual(json.loads(result.stdout), emitted['command'])
        finally:
            checked([*compose, 'down'], cwd=self.folder, env=self.env)


if __name__ == '__main__':
    unittest.main()
