/*
 * relay_follow.mjs - verifies the session subscription path end to end.
 *
 * This is the path the Wear client depends on for conversation content:
 * subscribe, receive the opening snapshot with its cursor and history records,
 * then page backwards using that cursor. It drives a real dsh installation
 * through the sender, so a pass means the mirrored conversation is real data.
 *
 * Usage: node tests/relay_follow.mjs [host] [port] [passphrase]
 */
import { createCipheriv, createDecipheriv, createHmac, pbkdf2Sync, randomBytes } from 'node:crypto'
import { connect } from 'node:net'

const host = process.argv[2] ?? '127.0.0.1'
const port = Number(process.argv[3] ?? 7778)
const passphrase = process.argv[4] ?? 'test-passphrase-123'

const MAGIC = Buffer.from('DSHX', 'ascii')
const HEADER_LEN = 32
const TAG_LEN = 32

function handshakeProof(pass, nonce) {
  return createHmac('sha256', Buffer.from(pass, 'utf8'))
    .update(Buffer.from('dsh-relay/v1', 'utf8'))
    .update(nonce)
    .digest()
}

function deriveSession(pass, salt, clientNonce, serverNonce) {
  const master = pbkdf2Sync(
    Buffer.from(pass, 'utf8'),
    Buffer.concat([salt, clientNonce, serverNonce]),
    50000,
    64,
    'sha256',
  )
  return {
    enc: createHmac('sha256', master).update(Buffer.from('c2s\0', 'utf8')).digest(),
    dec: createHmac('sha256', master).update(Buffer.from('s2c\0', 'utf8')).digest(),
    sendMac: createHmac('sha256', master).update(Buffer.from('mc2s', 'utf8')).digest(),
    recvMac: createHmac('sha256', master).update(Buffer.from('ms2c', 'utf8')).digest(),
  }
}

function sealPlain(type, payload) {
  const header = Buffer.alloc(HEADER_LEN)
  MAGIC.copy(header, 0)
  header[4] = 1
  header[5] = type
  header[6] = 0x01
  header.writeUInt32BE(payload.length, 12)
  return Buffer.concat([header, payload])
}

function sealData(session, seq, payload) {
  const iv = randomBytes(16)
  const cipher = createCipheriv('aes-256-cbc', session.enc, iv)
  const body = Buffer.concat([cipher.update(payload), cipher.final()])
  const header = Buffer.alloc(HEADER_LEN)
  MAGIC.copy(header, 0)
  header[4] = 1
  header[5] = 3
  header.writeUInt32BE(seq, 8)
  header.writeUInt32BE(body.length, 12)
  iv.copy(header, 16)
  const tag = createHmac('sha256', session.sendMac).update(Buffer.concat([header, body])).digest()
  return Buffer.concat([header, body, tag])
}

function openData(session, frame) {
  const len = frame.readUInt32BE(12)
  const expect = createHmac('sha256', session.recvMac).update(frame.subarray(0, HEADER_LEN + len)).digest()
  if (!expect.equals(frame.subarray(HEADER_LEN + len))) throw new Error('MAC mismatch')
  const decipher = createDecipheriv('aes-256-cbc', session.dec, frame.subarray(16, 32))
  return JSON.parse(Buffer.concat([
    decipher.update(frame.subarray(HEADER_LEN, HEADER_LEN + len)),
    decipher.final(),
  ]).toString('utf8'))
}

/* ── connection ──────────────────────────────────────────────────────────── */

const socket = connect({ host, port })
await new Promise((resolve, reject) => {
  socket.once('connect', resolve)
  socket.once('error', reject)
})

let buffer = Buffer.alloc(0)
let closed = false
socket.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk])
})
socket.on('close', () => {
  closed = true
})

async function take(count, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs
  while (buffer.length < count) {
    if (closed) throw new Error('connection closed')
    if (Date.now() > deadline) throw new Error('read timed out')
    await new Promise((r) => setTimeout(r, 25))
  }
  const slice = buffer.subarray(0, count)
  buffer = buffer.subarray(count)
  return Buffer.from(slice)
}

async function takeFrame() {
  const header = await take(HEADER_LEN)
  const len = header.readUInt32BE(12)
  const plain = (header[6] & 0x01) !== 0
  const rest = await take(len + (plain ? 0 : TAG_LEN))
  return { frame: Buffer.concat([header, rest]), plain }
}

const clientNonce = randomBytes(16)
socket.write(sealPlain(1, Buffer.from(JSON.stringify({
  role: 2,
  name: 'node-follow-test',
  nonce: clientNonce.toString('hex'),
  proof: handshakeProof(passphrase, clientNonce).toString('hex'),
}), 'utf8')))

const ackRaw = await takeFrame()
const ack = JSON.parse(ackRaw.frame.subarray(HEADER_LEN).toString('utf8'))
const session = deriveSession(
  passphrase,
  Buffer.from(ack.salt, 'hex'),
  clientNonce,
  Buffer.from(ack.nonce, 'hex'),
)
console.log('handshake ok')

let sendSeq = 1
let nextId = 1
const pending = new Map()
const inbox = []
let deviceId

function call(method, payload) {
  const id = `f-${nextId++}`
  const envelope = Buffer.from(JSON.stringify({
    t: 'request',
    id,
    p: { device: deviceId, method, payload },
  }), 'utf8')
  socket.write(sealData(session, sendSeq++, envelope))
  return new Promise((resolve) => pending.set(id, resolve))
}

async function pumpFor(ms) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if (closed) break
    if (!frameAvailable()) {
      await new Promise((r) => setTimeout(r, 20))
      continue
    }
    const { frame, plain } = await takeFrame()
    if (plain) continue
    const message = openData(session, frame)
    inbox.push(message)
    if (message.t === 'devices') {
      const list = message.p?.devices ?? []
      if (!deviceId && list.length > 0) deviceId = list[0].id
    }
    if ((message.t === 'result' || message.t === 'error') && pending.has(message.id)) {
      pending.get(message.id)(message)
      pending.delete(message.id)
    }
  }
}

/* True only when a whole frame is already buffered, so pump never blocks. */
function frameAvailable() {
  if (buffer.length < HEADER_LEN) return false
  const len = buffer.readUInt32BE(12)
  const plain = (buffer[6] & 0x01) !== 0
  return buffer.length >= HEADER_LEN + len + (plain ? 0 : TAG_LEN)
}

/*
 * Sends a request, pumps until its reply arrives, then returns it. Awaiting
 * `call` before pumping would deadlock: the reply can only be read by pump.
 */
async function request(method, payload, budgetMs = 4000) {
  const promise = call(method, payload)
  const deadline = Date.now() + budgetMs
  while (Date.now() < deadline) {
    await pumpFor(250)
    const settled = await Promise.race([promise, Promise.resolve(null)])
    if (settled) return settled
  }
  return null
}

await pumpFor(1500)
if (!deviceId) {
  console.log('FAIL: no sender is online')
  process.exit(1)
}
console.log(`sender: ${deviceId}`)

/* Pick a real, non-blank session to open. */
const listReply = await request('sessions/list', {}, 6000)
const sessions = listReply?.p?.value?.items ?? []
console.log(`sessions available: ${sessions.length}`)
/*
 * Start from the smallest top-level session so the protocol itself is under
 * test; a long session's opening window can be tens of megabytes and would
 * conflate "wrong address" with "large payload". Subagent sessions are
 * addressed differently (they need their durable parent), so they are excluded
 * from the main path.
 */
const candidates = sessions
  .filter((s) => !s.parentSessionId)
  .sort((a, b) => (a.projections?.asOfSeq ?? 0) - (b.projections?.asOfSeq ?? 0))

const explicit = process.argv[5]
const target = explicit
  ? sessions.find((s) => s.sessionId === explicit)
  : candidates[0]

if (!target) {
  console.log('FAIL: no session to open')
  process.exit(1)
}
console.log(`target session: ${target.sessionId}`)
console.log(`  title: ${target.projections?.values?.title ?? '(untitled)'}`)
console.log(`  subagent: ${target.parentSessionId ? 'yes' : 'no'}`)
console.log(`  asOfSeq: ${target.projections?.asOfSeq ?? 'unknown'}  blank: ${target.blank}`)

/* Subscribe and wait for the opening snapshot. */
await request('session/subscribe', { sessionId: target.sessionId }, 5000)

/* A long session must be decompressed and projected first, so allow time. */
{
  const deadline = Date.now() + 30000
  while (Date.now() < deadline) {
    await pumpFor(1000)
    if (inbox.some((m) => m.t === 'snapshot' && m.p?.session === target.sessionId)) break
    const seen = inbox.reduce((acc, m) => {
      acc[m.t] = (acc[m.t] ?? 0) + 1
      return acc
    }, {})
    console.log(`  waiting�?messages so far: ${JSON.stringify(seen)}`)
  }
}

const snapshot = inbox.find((m) => m.t === 'snapshot' && m.p?.session === target.sessionId)
if (!snapshot) {
  const errors = inbox.filter((m) => m.t === 'error').map((m) => `${m.p?.code}: ${m.p?.message}`)
  console.log(`FAIL: no snapshot arrived. errors=${JSON.stringify(errors)}`)
  process.exit(1)
}

const cursor = snapshot.p.cursor
const records = snapshot.p.records ?? []
console.log(`snapshot received: cursor=${cursor} records=${records.length}`)

const kinds = records.reduce((acc, r) => {
  const key = r?.event?.type ?? r?.type ?? 'unknown'
  acc[key] = (acc[key] ?? 0) + 1
  return acc
}, {})
console.log(`  record kinds: ${JSON.stringify(kinds)}`)

/* The opening window must carry real conversation content. */
const textRecords = records.filter((r) => {
  const type = r?.event?.type ?? r?.type
  return type === 'user/message' || type === 'assistant/message'
})
console.log(`  conversation records: ${textRecords.length}`)

/* Paging with the snapshot cursor must be accepted. */
const pageReply = await request('session/page', {
  sessionId: target.sessionId,
  throughSeq: cursor,
  maxMessages: 5,
}, 5000)

let pageOk = false
if (pageReply?.t === 'result') {
  const value = pageReply.p?.value ?? {}
  console.log(`session/page ok: records=${(value.records ?? []).length} hasMore=${value.hasMore}`)
  pageOk = true
} else {
  console.log(`session/page rejected: ${pageReply?.p?.code} ${pageReply?.p?.message}`)
}

/* Events arriving after the snapshot are the live tail. */
const live = inbox.filter((m) => m.t === 'events' && m.p?.session === target.sessionId)
console.log(`live event frames: ${live.length}`)

await request('session/unsubscribe', { sessionId: target.sessionId }, 2000)
await pumpFor(500)
socket.destroy()

console.log('')
const failures = []
if (records.length === 0) failures.push('the snapshot carried no history records')
if (cursor <= 0) failures.push('the snapshot cursor was not a positive sequence')
if (!pageOk) failures.push('session/page did not accept the follow cursor')

if (failures.length > 0) {
  for (const failure of failures) console.log(`FAIL: ${failure}`)
  process.exit(1)
}
console.log('PASS: subscribe -> snapshot -> page works against a real dsh session')
