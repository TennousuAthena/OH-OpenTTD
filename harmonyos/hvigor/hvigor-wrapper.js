#!/usr/bin/env node
// hvigor-wrapper.js — thin launcher that delegates to the DevEco Studio
// bundled hvigor CLI (hvigorw.js). Keeps the project wrapper stable across
// DevEco SDK updates without committing the (large) bundled hvigor toolchain.
//
// Resolution order:
//   $HVIGOR_WRAPPER  ->  DevEco Studio default location  ->  error
//
// Usage (from the harmonyos/ directory):
//   node hvigor/hvigor-wrapper.js [hvigor args...]

'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

function findHvigorw() {
  if (process.env.HVIGOR_WRAPPER && fs.existsSync(process.env.HVIGOR_WRAPPER)) {
    return process.env.HVIGOR_WRAPPER;
  }
  const candidates = [
    process.env.DEVECO_HOME ? path.join(process.env.DEVECO_HOME, 'hvigor/bin/hvigorw.js') : null,
    '/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js',
  ];
  for (const c of candidates) {
    if (c && fs.existsSync(c)) {
      return c;
    }
  }
  return null;
}

const nodeBin = process.execPath;
const wrapper = findHvigorw();
if (!wrapper) {
  console.error('[hvigor-wrapper] ERROR: could not locate hvigorw.js; set HVIGOR_WRAPPER or install DevEco Studio.');
  process.exit(1);
}

// hvigor must run with the project root (harmonyos/) as the working directory.
const args = process.argv.slice(2);
const res = spawnSync(nodeBin, [wrapper, ...args], { stdio: 'inherit' });
process.exit(res.status === null ? 1 : res.status);
