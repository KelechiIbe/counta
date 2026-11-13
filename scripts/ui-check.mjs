// Usage: node scripts/ui-check.mjs <file> <testid>...
// Exits 1, printing "missing in <file>: <ids>", unless each literal data-testid="<id>" occurs in the file.
import { readFileSync } from 'node:fs';

const [file, ...ids] = process.argv.slice(2);
if (!file || !ids.length) {
  console.error('usage: node scripts/ui-check.mjs <file> <testid>...');
  process.exit(2);
}
const src = readFileSync(file, 'utf8');
const missing = ids.filter((id) => !src.includes(`data-testid="${id}"`));
if (missing.length) {
  console.log(`missing in ${file}: ${missing.join(', ')}`);
  process.exit(1);
}
