/*
 * relay_methods.mjs - contract test for the sender's argument shaping.
 *
 * The sender's job is to translate the client's small vocabulary into dsh's
 * exact wire arguments. A wrong argument shape and a missing session are
 * distinguishable by error code: malformed arguments produce
 * `gateway/input-invalid` (or a boundary failure), while a well-formed request
 * for a session that does not exist produces `session/not-found`.
 *
 * Every case here therefore uses a deliberately non-existent session, so a
 * correct sender answers not-found and a broken one answers input-invalid.
 * Nothing is created, prompted, or mutated.
 *
 * Usage: node tests/relay_methods.mjs [host] [port] [passphrase]
 */
import { createCipheriv, createDecipheriv, createHmac, pbkdf2Sync, randomBytes } from 'node:crypto'
import { connect } from 'node:net'

const host = process.argv[2] ?? '127.0.0.1'
const port = Number(process.argv[3] ?? 7778)
const passphrase = process.argv[4] ?? 'test-passphrase-123'

const MAGIC = Buffer.from('DSHX', 'ascii')
const HEADER_LEN = 32
const TAG_LEN = 32
const ABSENT_SESSION = 'session-00000000-0000-4000-8000-000000000000'

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
  const expect = createHmac('sha256', session.recvMac)
    .update(frame.subarray(0, HEADER_LEN + len))
    .digest()
  if (!expect.equals(frame.subarray(HEADER_LEN + len))) throw new Error('MAC mismatch')
  const decipher = createDecipheriv('aes-256-cbc', session.dec, frame.subarray(16, 32))
  return JSON.parse(Buffer.concat([
    decipher.update(frame.subarray(HEADER_LEN, HEADER_LEN + len)),
    decipher.final(),
  ]).toString('utf8'))
}

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

function frameAvailable() {
  if (buffer.length < HEADER_LEN) return false
  const len = buffer.readUInt32BE(12)
  const plain = (buffer[6] & 0x01) !== 0
  return buffer.length >= HEADER_LEN + len + (plain ? 0 : TAG_LEN)
}

async function takeFrame() {
  /* Wait for a whole header before reading it: the first frame after the
   * handshake can arrive split across TCP segments. */
  while (buffer.length < HEADER_LEN) {
    if (closed) throw new Error('connection closed')
    await new Promise((r) => setTimeout(r, 15))
  }
  const header = buffer.subarray(0, HEADER_LEN)
  const len = header.readUInt32BE(12)
  const plain = (header[6] & 0x01) !== 0
  const total = HEADER_LEN + len + (plain ? 0 : TAG_LEN)
  while (buffer.length < total) {
    if (closed) throw new Error('connection closed')
    await new Promise((r) => setTimeout(r, 15))
  }
  const frame = Buffer.from(buffer.subarray(0, total))
  buffer = buffer.subarray(total)
  return frame
}

const clientNonce = randomBytes(16)
socket.write(sealPlain(1, Buffer.from(JSON.stringify({
  role: 2,
  name: 'node-methods-test',
  nonce: clientNonce.toString('hex'),
  proof: handshakeProof(passphrase, clientNonce).toString('hex'),
}), 'utf8')))

const ack = JSON.parse((await takeFrame()).subarray(HEADER_LEN).toString('utf8'))
const session = deriveSession(
  passphrase,
  Buffer.from(ack.salt, 'hex'),
  clientNonce,
  Buffer.from(ack.nonce, 'hex'),
)

let sendSeq = 1
let nextId = 1
const pending = new Map()
let deviceId

function send(method, payload) {
  const id = `m-${nextId++}`
  socket.write(sealData(session, sendSeq++, Buffer.from(JSON.stringify({
    t: 'request',
    id,
    p: { device: deviceId, method, payload },
  }), 'utf8')))
  return new Promise((resolve) => pending.set(id, resolve))
}

async function pumpFor(ms) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if (!frameAvailable()) {
      await new Promise((r) => setTimeout(r, 20))
      continue
    }
    const message = openData(session, await takeFrame())
    if (message.t === 'devices' && !deviceId && (message.p?.devices ?? []).length > 0) {
      deviceId = message.p.devices[0].id
    }
    if (pending.has(message.id) && (message.t === 'result' || message.t === 'error')) {
      pending.get(message.id)(message)
      pending.delete(message.id)
    }
  }
}

async function call(method, payload, budgetMs = 8000) {
  const promise = send(method, payload)
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

/* Remaining budget after handshake pumping is negligible; each case is bounded. */
const cases = [
  {
    name: 'sessions/list',
    payload: {},
    expect: 'ok',
    why: 'no arguments at all',
  },
  {
    name: 'session/modelCatalog',
    payload: {},
    expect: 'ok',
    why: 'no arguments at all',
  },
  {
    name: 'relay/status',
    payload: {},
    expect: 'ok',
    why: 'answered by the sender itself',
  },
  {
    name: 'session/page',
    payload: { sessionId: ABSENT_SESSION, throughSeq: 1, maxMessages: 2 },
    expect: 'not-found',
    why: 'sender must build the address object and pass a numeric throughSeq',
  },
  {
    name: 'session/prompt',
    payload: { sessionId: ABSENT_SESSION, text: 'argument shaping probe' },
    expect: 'not-found',
    why: 'sender must mint requestId and build the content parts array',
  },
  {
    name: 'session/cancel',
    payload: { sessionId: ABSENT_SESSION },
    expect: 'any-structured',
    why: 'cancel has no visible-session precondition on every build',
  },
  {
    name: 'session/subscribe',
    payload: { sessionId: ABSENT_SESSION },
    expect: 'ok',
    why: 'subscribing is local; dsh reports the failure asynchronously',
  },
]

let failures = 0

for (const testCase of cases) {
  const reply = await call(testCase.name, testCase.payload)
  if (reply === null) {
    console.log(`FAIL ${testCase.name}: no reply`)
    failures++
    continue
  }

  const code = reply.t === 'result' ? null : (reply.p?.code ?? 'unknown')
  const message = reply.t === 'result' ? '' : (reply.p?.message ?? '')

  /* A malformed argument is never an acceptable outcome. */
  const malformed =
    /input-invalid|boundary validation|arguments-invalid/i.test(code ?? '') ||
    /input-invalid|boundary validation|arguments-invalid/i.test(message)

  let verdict
  if (malformed) {
    verdict = 'FAIL'
    failures++
  } else if (testCase.expect === 'ok') {
    verdict = reply.t === 'result' ? 'ok  ' : 'FAIL'
    if (reply.t !== 'result') failures++
  } else if (testCase.expect === 'not-found') {
    verdict = /not-found/i.test(code ?? '') ? 'ok  ' : 'FAIL'
    if (!/not-found/i.test(code ?? '')) failures++
  } else {
    /* Structured failure of any kind is acceptable; a crash or silence is not. */
    verdict = reply.t === 'error' ? 'ok  ' : 'FAIL'
    if (reply.t !== 'error') failures++
  }

  console.log(`${verdict} ${testCase.name.padEnd(24)} ${code ?? 'result'}  (${testCase.why})`)
  if (verdict === 'FAIL' && message) {
    console.log(`       ${message.slice(0, 160)}`)
  }
}

socket.destroy()
console.log('')
console.log(failures === 0
  ? 'PASS: every mapped method reached dsh with well-formed arguments'
  : `FAIL: ${failures} method(s) got malformed-argument rejections`)
process.exit(failures === 0 ? 0 : 1)
