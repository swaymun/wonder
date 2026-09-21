import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import vm from 'node:vm';

test('old browser worker retires only Wonder shell caches and keeps pairing fragments', async () => {
  const handlers = new Map();
  const removed = [];
  const destinations = [];
  let unregistered = false;
  let skipped = false;
  const windows = [
    'https://wonder.example/pair#secret=local-test&offerId=test',
    'https://wonder.example/#/bots/old',
  ].map(url => ({ url, navigate: async destination => destinations.push(destination) }));
  vm.runInNewContext(await readFile(new URL('../../crates/wonderd/src/pairing_web/retire-worker.js', import.meta.url), 'utf8'), {
    URL,
    caches: { keys: async () => ['wonder-shell-v1-old', 'unrelated-cache'], delete: async key => removed.push(key) },
    self: {
      addEventListener: (type, handler) => handlers.set(type, handler),
      skipWaiting: async () => { skipped = true; },
      registration: { unregister: async () => { unregistered = true; } },
      clients: { matchAll: async () => windows },
    },
  });
  await handlers.get('install')();
  await new Promise((resolve, reject) => handlers.get('activate')({ waitUntil: promise => promise.then(resolve, reject) }));
  assert.equal(skipped, true);
  assert.equal(unregistered, true);
  assert.equal(handlers.has('fetch'), false);
  assert.deepEqual(removed, ['wonder-shell-v1-old']);
  assert.deepEqual(destinations, ['/pair#secret=local-test&offerId=test', '/pair']);
});
