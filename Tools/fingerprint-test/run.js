#!/usr/bin/env node
// Runs the privacy shield from WebEngine.swift against a stubbed browser and
// checks that it runs without errors, that values change between tabs, and that
// repeated reads inside one tab stay identical.
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'WebEngine.swift'), 'utf8');
const start = source.indexOf('private static func shieldScript');
const body = /"""\n([\s\S]*?)\n        """/.exec(source.slice(start))[1];

function shieldFor(seed) {
  return body
    .replace('\\(CloudflareExemptions.scriptList)', '[]')
    .replace('\\(webrtc)', 'true').replace('\\(gpc)', 'true').replace('\\(fingerprint)', 'true')
    .replace('\\(tor)', 'false').replace('\\(cfFriendly)', 'false').replace('\\(seed)', String(seed));
}

function makeWindow() {
  const w = {};
  w.window = w;
  w.location = { hostname: 'example.com' };
  w.Navigator = function () {};
  w.Navigator.prototype = { hardwareConcurrency: 8, deviceMemory: 8, maxTouchPoints: 5 };
  w.CanvasRenderingContext2D = function () {};
  w.CanvasRenderingContext2D.prototype = {
    measureText() { return { width: 123.456 }; },
    getImageData() { return { data: new Uint8ClampedArray(4096).fill(100) }; }
  };
  w.OffscreenCanvasRenderingContext2D = function () {};
  w.OffscreenCanvasRenderingContext2D.prototype = { getImageData() { return { data: new Uint8ClampedArray(4096).fill(100) }; } };
  w.HTMLCanvasElement = function () {};
  w.HTMLCanvasElement.prototype = { toDataURL() { return 'data:'; }, toBlob() {} };
  w.Element = function () {};
  w.Element.prototype = {
    getBoundingClientRect() { return { width: 50.25, height: 20.5 }; },
    getClientRects() { return [{ width: 50.25, height: 20.5 }]; }
  };
  w.Range = function () {};
  w.Range.prototype = { getBoundingClientRect() { return { width: 10, height: 10 }; }, getClientRects() { return []; } };
  const gl = () => ({
    getExtension() { return {}; },
    getSupportedExtensions() { return ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'webgl_debug_renderer_info']; },
    getParameter() { return 1; }, readPixels() {}
  });
  w.WebGLRenderingContext = function () {}; w.WebGLRenderingContext.prototype = gl();
  w.WebGL2RenderingContext = function () {}; w.WebGL2RenderingContext.prototype = gl();
  w.StorageManager = function () {};
  w.StorageManager.prototype = { estimate() { return Promise.resolve({ quota: 1000000000, usage: 5 }); } };
  w.AudioBuffer = function () {};
  w.AudioBuffer.prototype = { getChannelData() { return new Float32Array(2048); } };
  w.AnalyserNode = function () {}; w.AnalyserNode.prototype = { getFloatFrequencyData() {} };
  w.FontFaceSet = function () {}; w.FontFaceSet.prototype = { check() { return true; }, forEach() {} };
  w.HTMLIFrameElement = function () {}; w.HTMLIFrameElement.prototype = {};
  w.Document = function () {}; w.Document.prototype = {};
  w.document = { referrer: '', createElement() { return {}; } };
  w.Date = Date; w.Intl = Intl; w.URL = URL;
  return w;
}

function run(seed) {
  const w = makeWindow();
  vm.createContext(w);
  vm.runInContext(shieldFor(seed), w);
  return w;
}

let failures = 0;
function check(ok, message) { if (!ok) { failures++; console.log('FAIL', message); } }

const a1 = run(111), a2 = run(111), b = run(222);
const width = w => w.CanvasRenderingContext2D.prototype.measureText.call({}).width;
const rect = w => w.Element.prototype.getBoundingClientRect.call({}).width;
const exts = w => w.WebGLRenderingContext.prototype.getSupportedExtensions.call({}).join(',');
const px = w => Array.from(w.CanvasRenderingContext2D.prototype.getImageData.call({}).data).join(',');

check(width(a1) === width(a1), 'measureText is not stable inside one tab');
check(width(a1) === width(a2), 'same seed should give the same measureText');
check(width(a1) !== width(b), 'measureText should differ between tabs');
check(Math.abs(width(a1) - 123.456) < 0.0001, 'measureText change is too large');
check(rect(a1) === rect(a1), 'rect is not stable inside one tab');
check(Math.abs(rect(a1) - 50.25) < 0.0001, 'rect change is too large');
check(rect(a1) !== rect(b), 'rect should differ between tabs');
check(exts(a1) === exts(a1), 'extension order is not stable');
check(exts(a1).split(',').sort().join() === 'A,B,C,D,E,F,G,H', 'extension set changed or debug info not hidden');
check(exts(a1) !== exts(b), 'extension order should differ between tabs');
check(px(a1) === px(a1), 'canvas read-back is not stable inside one tab');
check(px(a1) !== px(b), 'canvas read-back should differ between tabs');
check(!('hardwareConcurrency' in a1.Navigator.prototype) || a1.Navigator.prototype.hardwareConcurrency === undefined, 'hardwareConcurrency should be hidden');

a1.StorageManager.prototype.estimate().then(r => {
  check(r.quota > 980000000 && r.quota < 1010000000, 'quota change is out of range');
  console.log(failures ? failures + ' FAILURE(S)' : 'PASS');
  process.exit(failures ? 1 : 0);
});
