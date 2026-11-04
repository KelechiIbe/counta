// The stand-in e-Tax, payments page and checkout on fixed ports, for the browser tests of the whole flow.
// node dist/test/serve-mock.js [etaxPort] [flwPort]
import { startMock } from './mock.js';
const m = await startMock({ etaxPort: Number(process.argv[2] || 54640), flwPort: Number(process.argv[3] || 54641) });
console.log(JSON.stringify({ etax: m.etaxUrl, flw: m.flwUrl }));
