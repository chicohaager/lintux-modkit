// Tests for the ZFW helper in web/common.js against a fake ZFW API (rules, apply, commit).
//   node tools/test-web-zfw.mjs
// common.js is a browser script: it runs in a vm context with fetch and localStorage stubbed.
import fs from 'node:fs'
import path from 'node:path'
import vm from 'node:vm'
import assert from 'node:assert/strict'

const src = fs.readFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), '..', 'web', 'common.js'), 'utf8')

function world(rules, lan = '192.0.2.0/24', policy = 'deny') {
  const zfwState = { lan, default_policy: policy, rules: structuredClone(rules) }
  const calls = []
  const json = (data, status = 200) => ({ ok: status < 300, status, headers: { get: () => 'application/json' }, json: async () => data, text: async () => '' })
  const fetch = async (url, opts = {}) => {
    const p = url.replace('/v2/zfw/api', '')
    calls.push(`${opts.method || 'GET'} ${p}`)
    if (p === '/rules' && (opts.method || 'GET') === 'GET') return json(structuredClone(zfwState))
    if (p === '/rules') { Object.assign(zfwState, JSON.parse(opts.body)); return json({}) }
    if (p === '/apply' || p === '/commit') return json({})
    if (p === '/health') return json({ status: 'ok' })
    return json({}, 404)
  }
  const ctx = { fetch, localStorage: { getItem: () => null, setItem() {} }, document: {}, console, setTimeout, URL, Blob: class {} }
  vm.createContext(ctx)
  vm.runInContext(src + '\nthis.zfw = zfw;', ctx)
  return { zfw: ctx.zfw, state: zfwState, calls }
}

const allowUdp = (port, extra = {}) => ({ id: 'h', enabled: true, action: 'allow', protocol: 'udp', source: { type: 'any', value: '' }, ports: { type: 'list', list: [port] }, ...extra })
let n = 0
const t = async (name, fn) => { await fn(); n++; console.log(`ok   ${name}`) }

await t('openUdp keeps the old rule: id mod-udp-<port>, source any, apply unsafe + commit', async () => {
  const w = world([])
  await w.zfw.openUdp(51820, 'WireGuard', 'n')
  const r = w.state.rules[0]
  assert.equal(r.id, 'mod-udp-51820'); assert.equal(r.protocol, 'udp'); assert.equal(r.source.type, 'any')
  assert.deepEqual(w.calls, ['GET /rules', 'POST /rules', 'POST /apply', 'POST /commit'])
})

await t('open tcp from lan: source is the LAN range ZFW has', async () => {
  const w = world([])
  await w.zfw.open(9100, 'tcp', 'node_exporter', 'n', 'lan')
  const r = w.state.rules[0]
  assert.equal(r.id, 'mod-tcp-9100'); assert.equal(r.protocol, 'tcp'); assert.deepEqual(r.source, { type: 'range', value: '192.0.2.0/24' })
})

await t('allows: a udp rule does not cover tcp; a lan rule covers from lan but not from any', async () => {
  const w = world([allowUdp(9100), allowUdp(9200, { protocol: 'tcp', source: { type: 'range', value: '192.0.2.0/24' } })])
  assert.equal(await w.zfw.allows(9100, 'tcp'), false)
  assert.equal(await w.zfw.allows(9100, 'udp'), true)
  assert.equal(await w.zfw.allows(9200, 'tcp', 'lan'), true)
  assert.equal(await w.zfw.allows(9200, 'tcp', 'any'), false)
  const other = world([allowUdp(9300, { protocol: 'tcp', source: { type: 'range', value: '198.51.100.0/24' } })])
  assert.equal(await other.zfw.allows(9300, 'tcp', 'lan'), false)
})

await t('open adds nothing when a rule covers the port, still applies', async () => {
  const w = world([allowUdp(9100, { protocol: 'both' })])
  await w.zfw.open(9100, 'tcp', 'x', 'n', 'lan')
  assert.equal(w.state.rules.length, 1)
  assert.deepEqual(w.calls, ['GET /rules', 'POST /apply', 'POST /commit'])
})

await t('open from lan without a LAN range throws, changes nothing', async () => {
  const w = world([], '')
  await assert.rejects(() => w.zfw.open(9100, 'tcp', 'x', 'n', 'lan'), /no LAN range/)
  assert.deepEqual(w.calls, ['GET /rules'])
})

await t('close removes only its own id for that protocol', async () => {
  const w = world([allowUdp(9100, { id: 'mod-tcp-9100', protocol: 'tcp' }), allowUdp(9100, { id: 'mod-udp-9100' }), allowUdp(9100, { id: 'by-hand', protocol: 'tcp' })])
  assert.equal(await w.zfw.close(9100, 'tcp'), true)
  assert.deepEqual(w.state.rules.map((r) => r.id), ['mod-udp-9100', 'by-hand'])
  assert.equal(await w.zfw.close(9100, 'tcp'), false)
})

console.log(`web zfw: ${n} ok, 0 FAIL`)
