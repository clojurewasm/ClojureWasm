// Browser-compatible module and byte-for-byte kernel oracle. Run from repo root:
// node docs/examples/fractal/verify.mjs
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

let reference;
for (const artifact of ['kernel', 'kernel_simd']) {
  const module = await WebAssembly.compile(readFileSync(`docs/examples/fractal/${artifact}.wasm`));
  assert.deepEqual(WebAssembly.Module.imports(module), []);
  const { exports: e } = await WebAssembly.instantiate(module);
  assert.equal(e.fb_cap(), 1048576);
  const checks = [];
  for (const args of [[-.5, 0, 3.5 / 512, 512, 512, 256],
                      [-.743643887037151, .13182590420533, 1e-6, 128, 128, 2000],
                      [-.5, 0, .1, 31, 29, 80], [0, 0, .01, 1024, 1024, 1],
                      [0, 0, 0, 1, 1, 7], [2, 0, 0, 1, 1, 7]]) {
    const [cx, cy, scale, w, h, limit] = args;
    assert.equal(e.set_view(cx, cy, scale), 0);
    const total = e.render(w, h, limit);
    const scalar = Buffer.from(new Uint8Array(e.memory.buffer, e.fb_ptr(), w * h * 4));
    assert.equal(e.render_simd(w, h, limit), total);
    assert.deepEqual(Buffer.from(new Uint8Array(e.memory.buffer, e.fb_ptr(), w * h * 4)), scalar);
    for (let i = 3; i < scalar.length; i += 4) assert.equal(scalar[i], 255);
    if (cx === 0 && cy === 0 && scale === 0) {
      assert.equal(total, 7n);
      assert.deepEqual(scalar, Buffer.from([0, 0, 0, 255]));
    }
    if (cx === 2 && scale === 0) assert.equal(total, 2n);
    checks.push([total, scalar]);
  }
  const before = Buffer.from(new Uint8Array(e.memory.buffer, e.fb_ptr(), 16));
  for (const fn of [e.render, e.render_simd]) {
    for (const args of [[0, 0, 1, 0, 1, 1], [0, 0, 1, 1025, 1024, 1], [NaN, 0, 1, 1, 1, 1]]) {
      const [cx, cy, scale, w, h, limit] = args;
      assert.equal(e.set_view(cx, cy, scale), Number.isFinite(cx) ? 0 : -1);
      assert.equal(fn(w, h, limit), -1n);
      assert.deepEqual(Buffer.from(new Uint8Array(e.memory.buffer, e.fb_ptr(), 16)), before);
    }
  }
  if (reference) assert.deepEqual(checks, reference);
  else reference = checks;
  console.log(`PASS ${artifact}: zero imports, scalar/vector parity, alpha, odd tail, invalid input, known points`);
}
