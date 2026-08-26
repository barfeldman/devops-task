// Smoke test: boots the app on an ephemeral port and asserts the key endpoints
// respond as expected. Uses only the Node.js standard library.
const { spawn } = require('child_process');
const http = require('http');

const PORT = process.env.SMOKE_PORT || 18080;
const server = spawn('node', ['app.js'], {
  cwd: __dirname + '/..',
  env: { ...process.env, PORT: String(PORT) },
  stdio: 'inherit',
});

const get = (path) =>
  new Promise((resolve, reject) => {
    const req = http.get(`http://127.0.0.1:${PORT}${path}`, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
  });

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  let failed = false;
  try {
    // Wait for the server to accept connections
    for (let i = 0; i < 50; i++) {
      try {
        await get('/ready');
        break;
      } catch {
        await wait(200);
      }
    }

    const checks = [
      ['/ready', 200],
      ['/live', 200],
      ['/my-app', 200],
      ['/about', 200],
      ['/metrics', 200],
      ['/classified', 401],
    ];

    for (const [path, expected] of checks) {
      const res = await get(path);
      if (res.status !== expected) {
        console.error(`FAIL ${path}: expected ${expected}, got ${res.status}`);
        failed = true;
      } else {
        console.log(`OK   ${path} -> ${res.status}`);
      }
    }
  } catch (err) {
    console.error('Smoke test error:', err.message);
    failed = true;
  } finally {
    server.kill('SIGTERM');
  }
  process.exit(failed ? 1 : 0);
})();
