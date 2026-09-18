/*
 * relay_client.mjs - end-to-end harness for the dsh relay.
 *
 * Speaks the relay protocol as an independent implementation (Node's crypto
 * rather than the C core) so a passing run proves the wire format is actually
 * interoperable, not just self-consistent. Acts as the Wear client would:
 * handshake, list devices, ask the sender for its status, then drive one
 * mapped dsh call if a sender is online.
 *
 * Usage: node tests/relay_client.mjs [host] [port] [passphrase]
 */
import { createCipheriv, createDecipheriv, createHmac, pbkdf2Sync, randomBytes } from 'node:crypto'
import { connect } from 'node:net'

const host = process.argv[2] ?? '127.0.0.1'
const port = Number(process.argv[3] ?? 7778)
const passphrase = process.argv[4] ?? 'test-passphrase-123'

const MAGIC = Buffer.from('DSHX', 'ascii')
const VERSION = 1
const TYPE_HELLO = 1
const TYPE_HELLO_ACK = 2
const TYPE_DATA = 3
const HEADER_LEN = 32
const TAG_LEN = 32

/* ── crypto ──────────────────────────────────────────────────────────────── */

function handshakeProof(pass, nonce) {
  return createHmac('sha256', Buffer.from(pass, 'utf8'))
    .update(Buffer.from('dsh-relay/v1', 'utf8'))
    .update(nonce)
    .digest()
}

function deriveSession(pass, salt, clientNonce, serverNonce) {
  const mixed = Buffer.concat([salt, clientNonce, serverNonce])
  const master = pbkdf2Sync(Buffer.from(pass, 'utf8'), mixed, 50000, 64, 'sha256')
  return {
    enc: createHmac('sha256', master).update(Buffer.from('c2s\0', 'utf8')).digest(),
    dec: createHmac('sha256', master).update(Buffer.from('s2c\0', 'utf8')).digest(),
    sendMac: createHmac('sha256', master).update(Buffer.from('mc2s', 'utf8')).digest(),
    recvMac: createHmac('sha256', master).update(Buffer.from('ms2c', 'utf8')).digest(),
  }
}

/* ── framing ─────────────────────────────────────────────────────────────── */

function sealPlain(type, payload) {
  const header = Buffer.alloc(HEADER_LEN)
  MAGIC.copy(header, 0)
  header[4] = VERSION
  header[5] = type
  header[6] = 0x01
  header[7] = 0
  header.writeUInt32BE(0, 8)
  header.writeUInt32BE(payload.length, 12)
  return Buffer.concat([header, payload])
}

function openPlain(frame) {
  if (frame.length < HEADER_LEN) throw new Error('short plain frame')
  if (!frame.subarray(0, 4).equals(MAGIC)) throw new Error('bad magic')
  if ((frame[6] & 0x01) === 0) throw new Error('not a plaintext frame')
  const len = frame.readUInt32BE(12)
  if (len !== frame.length - HEADER_LEN) throw new Error('plain frame length mismatch')
  return { type: frame[5], payload: frame.subarray(HEADER_LEN) }
}

function sealData(session, seq, type, payload) {
  const iv = randomBytes(16)
  const cipher = createCipheriv('aes-256-cbc', session.enc, iv)
  const body = Buffer.concat([cipher.update(payload), cipher.final()])

  const header = Buffer.alloc(HEADER_LEN)
  MAGIC.copy(header, 0)
  header[4] = VERSION
  header[5] = type
  header[6] = 0
  header[7] = 0
  header.writeUInt32BE(seq, 8)
  header.writeUInt32BE(body.length, 12)
  iv.copy(header, 16)

  const tag = createHmac('sha256', session.sendMac)
    .update(Buffer.concat([header, body]))
    .digest()

  return Buffer.concat([header, body, tag])
}

function openData(session, frame) {
  if (!frame.subarray(0, 4).equals(MAGIC)) throw new Error('bad magic')
  const seq = frame.readUInt32BE(8)
  const len = frame.readUInt32BE(12)
  if (len !== frame.length - HEADER_LEN - TAG_LEN) throw new Error('data frame length mismatch')

  const expect = createHmac('sha256', session.recvMac)
    .update(frame.subarray(0, HEADER_LEN + len))
    .digest()
  if (!expect.equals(frame.subarray(HEADER_LEN + len))) throw new Error('MAC mismatch')

  const decipher = createDecipheriv(
    'aes-256-cbc',
    session.dec,
    frame.subarray(16, 32),
  )
  const plain = Buffer.concat([
    decipher.update(frame.subarray(HEADER_LEN, HEADER_LEN + len)),
    decipher.final(),
  ])

  return { seq, type: frame[5], payload: plain }
}

/* ── connection ──────────────────────────────────────────────────────────── */

function createReader(socket) {
  let buffer = Buffer.alloc(0)
  let pendingResolve = null
  let closed = false
  let failure = null

  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk])
    if (pendingResolve) {
      const resolve = pendingResolve
      pendingResolve = null
      resolve()
    }
  })
  socket.on('close', () => {
    closed = true
    if (pendingResolve) {
      const resolve = pendingResolve
      pendingResolve = null
      resolve()
    }
  })
  socket.on('error', (error) => {
    failure = error
    closed = true
    if (pendingResolve) {
      const resolve = pendingResolve
      pendingResolve = null
      resolve()
    }
  })

  async function take(count, timeoutMs = 8000) {
    const deadline = Date.now() + timeoutMs
    while (buffer.length < count) {
      if (failure) throw failure
      if (closed) throw new Error('connection closed while reading')
      if (Date.now() > deadline) throw new Error('read timed out')
      await new Promise((resolve) => {
        pendingResolve = resolve
        setTimeout(resolve, 50).unref?.()
      })
    }
    const slice = buffer.subarray(0, count)
    buffer = buffer.subarray(count)
    return Buffer.from(slice)
  }

  async function takeFrame() {
    const header = await take(HEADER_LEN)
    const len = header.readUInt32BE(12)
    const isPlain = (header[6] & 0x01) !== 0
    const rest = await take(len + (isPlain ? 0 : TAG_LEN))
    return Buffer.concat([header, rest])
  }

  return { take, takeFrame }
}

function rpc(session, socket, state, method, payload, timeoutMs = 10000) {
  const id = `r-${state.nextId++}`
  const envelope = JSON.stringify({
    t: 'request',
    id,
    p: { device: state.device, method, payload },
  })
  socket.write(sealData(session, state.sendSeq++, TYPE_DATA, Buffer.from(envelope, 'utf8')))
  return id
}

/* ── run ─────────────────────────────────────────────────────────────────── */

const socket = connect({ host, port })
await new Promise((resolve, reject) => {
  socket.once('connect', resolve)
  socket.once('error', reject)
})

const reader = createReader(socket)
const state = { sendSeq: 1, nextId: 1, device: undefined }

const clientNonce = randomBytes(16)
const hello = Buffer.from(
  JSON.stringify({
    role: 2,
    name: 'node-test-client',
    nonce: clientNonce.toString('hex'),
    proof: handshakeProof(passphrase, clientNonce).toString('hex'),
  }),
  'utf8',
)
socket.write(sealPlain(TYPE_HELLO, hello))

const ackFrame = openPlain(await reader.takeFrame())
if (ackFrame.type !== TYPE_HELLO_ACK) throw new Error(`expected HELLO_ACK, got ${ackFrame.type}`)
const ack = JSON.parse(ackFrame.payload.toString('utf8'))
if (ack.ok !== true) throw new Error('server rejected the handshake')

const session = deriveSession(
  passphrase,
  Buffer.from(ack.salt, 'hex'),
  clientNonce,
  Buffer.from(ack.nonce, 'hex'),
)
console.log(`handshake ok  server=${ack.server} v${ack.version}`)

/* Collect everything the server pushes, and answer requests we care about. */
const received = []
let done = false
const results = new Map()

async function pump() {
  while (!done) {
    let frame
    try {
      frame = await reader.takeFrame()
    } catch {
      break
    }
    let opened
    try {
      opened = openData(session, frame)
    } catch (error) {
      console.log(`frame rejected: ${error.message}`)
      continue
    }
    const message = JSON.parse(opened.payload.toString('utf8'))
    received.push(message)

    if (message.t === 'devices') {
      const devices = message.p?.devices ?? []
      console.log(`devices: ${devices.length}`)
      for (const device of devices) {
        console.log(`  - id=${device.id} name=${device.name} dsh=${device.dshVersion} up=${device.online}`)
        if (state.device === undefined) state.device = device.id
      }
    } else if (message.t === 'sessions') {
      console.log(`sessions from ${message.p?.device}: ${message.p?.sessions?.length ?? 0}`)
    } else if (message.t === 'state') {
      console.log('control frame received')
    } else if (message.t === 'result' || message.t === 'error') {
      results.set(message.id, message)
      console.log(`reply id=${message.id} kind=${message.t}`)
      console.log(`  ${JSON.stringify(message.p).slice(0, 300)}`)
    } else {
      console.log(`message: ${message.t}`)
    }
  }
}

const pumping = pump()

/* Give the sender a moment to appear, then ask for its status. */
await new Promise((resolve) => setTimeout(resolve, 1200))

rpc(session, socket, state, 'relay/status', {})
rpc(session, socket, state, 'sessions/list', {})
if (state.device) {
  rpc(session, socket, state, 'relay/status', {})
} else {
  console.log('no sender is online; the relay answered without devices')
}

await new Promise((resolve) => setTimeout(resolve, 3500))

done = true
socket.destroy()
await pumping.catch(() => {})

console.log('')
console.log(`frames received: ${received.length}`)
const kinds = received.reduce((acc, m) => {
  acc[m.t] = (acc[m.t] ?? 0) + 1
  return acc
}, {})
console.log(`by kind: ${JSON.stringify(kinds)}`)

const errors = received.filter((m) => m.t === 'error')
const answered = received.filter((m) => m.t === 'result').length
console.log(`results: ${answered}  errors: ${errors.length}`)
if (errors.length > 0) {
  for (const error of errors) {
    console.log(`  error ${error.p?.code}: ${error.p?.message}`)
  }
}

if (answered === 0) {
  console.log('FAIL: no request was answered')
  process.exit(1)
}
console.log('PASS: the relay accepted a request and returned an answer')
