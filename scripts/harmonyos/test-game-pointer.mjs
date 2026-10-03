#!/usr/bin/env node
// Exercise the production visibility policy with only the device APIs mocked.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';

const path = new URL('../../harmonyos/entry/src/main/ets/platform/GamePointer.ets', import.meta.url);
const source = readFileSync(path, 'utf8').replace(/^import .*;\n/gm, '').replace('export class', 'class');
const writes = [];
let unsupported = false;
let warnings = 0;
const pointer = {
  visible: true,
  setPointerVisibleSync(visible) {
    if (unsupported) throw new Error('Capability unavailable');
    writes.push(visible);
    this.visible = visible;
  },
  isPointerVisibleSync() { return this.visible; },
};
const GamePointer = runInNewContext(`${stripTypeScriptTypes(source)}\nGamePointer;`, {
  pointer,
  hilog: { warn() { ++warnings; } },
});

GamePointer.setActive(true);
GamePointer.setFocused(true);
GamePointer.setHovered(true);
assert.deepEqual(writes, [], 'loading screen keeps the OS pointer');
GamePointer.setReady(true);
assert.deepEqual(writes, [false], 'ready, hovered, focused game hides the OS pointer');
GamePointer.setHovered(true);
assert.deepEqual(writes, [false], 'duplicate hover does not reapply visibility');
pointer.visible = true;
GamePointer.setHovered(true);
assert.deepEqual(writes, [false, false], 'movement recovers an OS pointer visibility reset');
GamePointer.setHovered(false);
assert.equal(writes.at(-1), true, 'leaving the surface restores the pointer');
GamePointer.setHovered(true);
GamePointer.setFocused(false);
assert.equal(writes.at(-1), true, 'focus loss restores the pointer even while the ability is foreground');
GamePointer.setFocused(true);
assert.equal(writes.at(-1), false, 'focus regain over the game hides the pointer');
GamePointer.setActive(false);
assert.equal(writes.at(-1), true, 'background or hidden window restores the pointer');
GamePointer.setActive(true);
assert.equal(writes.at(-1), false, 'resume over the game hides the pointer');
GamePointer.setReady(false);
assert.equal(writes.at(-1), true, 'surface teardown or engine exit restores the pointer');
const beforeRebuild = writes.length;
GamePointer.setReady(true);
assert.equal(writes.length, beforeRebuild, 'rebuilt surface waits for fresh hover');
unsupported = true;
GamePointer.setHovered(true);
assert.equal(warnings, 1, 'unsupported pointer API is logged without crashing');
assert.equal(writes.length, beforeRebuild, 'failed hide is not recorded as successful');
unsupported = false;
GamePointer.setHovered(true);
assert.equal(writes.at(-1), false, 'the next event retries a failed hide');
GamePointer.setReady(false);
assert.equal(writes.at(-1), true, 'cleanup restores the pointer after retry');
console.log('PASS: game pointer hover, focus, background, rebuild, exit, and API failure recovery');
