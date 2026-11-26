// Entry point for `node --test test_node/` (the "test" script in package.json) on Node 21 and later.
// There the runner reads its arguments as glob patterns, so `test_node/` matches only this directory,
// and the runner starts the directory as a script, which runs this file (the package is
// "type": "module"). Load every *.test.mjs file next to it, in name order, so that the command runs the
// whole suite. Running a test file directly, or a plain `node --test`, does not use this file.
import { readdirSync } from 'node:fs';

const here = new URL('./', import.meta.url);
for (const name of readdirSync(here).filter((n) => n.endsWith('.test.mjs')).sort()) {
  await import(new URL(name, here).href);
}
