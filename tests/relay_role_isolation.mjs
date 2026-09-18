/*
 * relay_role_isolation.mjs - proves the two ports actually enforce roles.
 *
 * The relay listens on a sender port and a client port, and the port a
 * connection arrives on decides what that peer is allowed to claim in its
 * HELLO. Splitting the ports is only worth anything if a forged role is
 * refused, so this drives all four combinations and checks the two that must
 * fail actually do.
 *
 * Usage: node tests/relay_role_isolation.mjs [host] [senderPort] [clientPort] [passphrase]
 */
import { createHmac, randomBytes } from 'node:crypto'
import { connect } from 'node:net'

const host = process.argv[2] ?? '127.0.0.1'
const senderPort = Number(process.argv[3] ?? 7777)
const clientPort = Number(process.argv[4] ?? 7778)
const passphrase = process.argv[5] ?? 'test-passphrase-123'

const ROLE_SENDER = 1
const ROLE_CLIENT = 2

function sealHello(role, name) {
  const nonce = randomBytes(16)
  const proof = createHmac('sha256', Buffer.from(passphrase, 'utf8'))
    .update(Buffer.from('dsh-relay/v1', 'utf8'))
    .update(nonce)
    .digest()

  const body = Buffer.from(JSON.stringify({
    role,
    name,
    nonce: nonce.toString('hex'),
    proof: proof.toString('hex'),
  }), 'utf8')

  const header = Buffer.alloc(32)
  Buffer.from('DSHX', 'ascii').copy(header, 0)
  header[4] = 1
  header[5] = 1        /* HELLO */
  header[6] = 0x01     /* plaintext handshake frame */
  header[7] = 0
  header.writeUInt32BE(0, 8)
  header.writeUInt32BE(body.length, 12)

  return Buffer.concat([header, body])
}

/** Returns 'accepted', 'refused', or 'unreachable'. */
function attempt(port, role, timeoutMs = 4000) {
  return new Promise((resolve) => {
    const socket = connect({ host, port })
    let settled = false
    let buffer = Buffer.alloc(0)

    const finish = (verdict) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      socket.destroy()
      resolve(verdict)
    }

    const timer = setTimeout(() => finish('unreachable'), timeoutMs)

    socket.on('connect', () => socket.write(sealHello(role, 'role-probe')))
    socket.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk])
      if (buffer.length < 32) return
      /* The server answers a good HELLO with a plaintext HELLO_ACK. */
      if (buffer[5] === 2 && (buffer[6] & 0x01) !== 0) {
        finish('accepted')
      } else {
        finish('refused')
      }
    })
    /* A refused handshake closes the socket without a reply. */
    socket.on('close', () => finish('refused'))
    socket.on('error', () => finish('unreachable'))
  })
}

const results = []
async function check(label, port, role, expected) {
  const actual = await attempt(port, role)
  const pass = actual === expected
  results.push(pass)
  console.log(`${pass ? 'ok  ' : 'FAIL'} ${label.padEnd(46)} ${actual} (expected ${expected})`)
}

console.log(`sender port ${senderPort}, client port ${clientPort}`)
console.log('')

await check('sender role on the sender port', senderPort, ROLE_SENDER, 'accepted')
await check('client role on the client port', clientPort, ROLE_CLIENT, 'accepted')
await check('client role on the sender port', senderPort, ROLE_CLIENT, 'refused')
await check('sender role on the client port', clientPort, ROLE_SENDER, 'refused')

const failures = results.filter((r) => !r).length
console.log('')
console.log(failures === 0
  ? 'PASS: each port accepts only its own role'
  : `FAIL: ${failures} combination(s) wrong`)
process.exit(failures === 0 ? 0 : 1)
