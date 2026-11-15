// Tests for describe() in web/common.js: the message a module shows for an API error.
//   node tools/test-web-common.mjs
// common.js is a browser script: it runs in a vm context like in tools/test-web-zfw.mjs.
import fs from 'node:fs'
import path from 'node:path'
import vm from 'node:vm'
import assert from 'node:assert/strict'

const src = fs.readFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), '..', 'web', 'common.js'), 'utf8')
const ctx = { localStorage: { getItem: () => null, setItem() {} }, document: {}, console, setTimeout, URL, Blob: class {} }
vm.createContext(ctx)
vm.runInContext(src + '\nthis.describe = describe; this.ApiError = ApiError;', ctx)
const { describe, ApiError } = ctx

let fails = 0
function check(name, fn) {
  try { fn(); console.log(`ok   ${name}`) } catch (e) { fails++; console.log(`FAIL ${name}: ${e.message}`) }
}

check('401 asks to sign in again', () => {
  assert.match(describe(new ApiError(401, 'auth_invalid', 'invalid session: token expired')), /reload the ZimaOS page/)
})
check('403 auth_forbidden names the administrator', () => {
  const msg = describe(new ApiError(403, 'auth_forbidden', 'only the ZimaOS administrator may use this module'))
  assert.match(msg, /Only the ZimaOS administrator/)
  assert.match(msg, /main account/)
})
check('another 403 keeps the server message', () => {
  assert.equal(describe(new ApiError(403, 'csrf', 'cross-origin request refused')), 'cross-origin request refused')
})
console.log(`web common: ${3 - fails} ok, ${fails} FAIL`)
process.exit(fails ? 1 : 0)
