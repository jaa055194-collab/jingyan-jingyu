// Page end of the JSON bridge (PROTOCOL.md sections 1-3): binds the transport, queues host
// messages until hello-ack and goes quiet after a fatal error. No DOM and no three.js, so
// node --test drives it with a fake transport. Written for this package.
import { parseEnvelope, encodeEnvelope, errorPayload } from './protocol.js';

export const QUEUE_LIMIT = 64;

function errorText(e) {
  return e && typeof e.message === 'string' ? e.message : String(e);
}

// The host transport: Android's injected Street3DBridge (WebViewCompat.addWebMessageListener),
// or null when the page runs outside the app.
export function hostTransport(scope = globalThis) {
  const b = scope.Street3DBridge;
  return b && typeof b.postMessage === 'function' ? b : null;
}

export class Bridge {
  // transport: { postMessage(string) }; the bridge sets transport.onmessage and reads event.data.
  constructor(transport, { onMessage = () => {}, now = () => Date.now() } = {}) {
    this.transport = transport;
    this.onMessage = onMessage;
    this.now = now;
    this.acked = false;
    this.dead = false;
    this.queue = [];
    this.dropped = 0;
    this.sent = 0;
    this.received = 0;
    transport.onmessage = (event) => {
      this.receive(event !== null && typeof event === 'object' && 'data' in event ? event.data : event);
    };
  }

  // Page -> host. After a fatal error only error messages still go out.
  send(type, payload = {}, opts = {}) {
    if (this.dead && type !== 'error') return false;
    try {
      this.transport.postMessage(encodeEnvelope(type, payload, { ts: this.now(), ...opts }));
      this.sent += 1;
      return true;
    } catch {
      return false;
    }
  }

  error(code, message, { fatal = false, ref } = {}) {
    const p = errorPayload(code, message, { fatal, ref });
    const ok = this.send('error', p);
    if (p.fatal) { this.dead = true; this.queue = []; }
    return ok;
  }

  // Host -> page. Before hello-ack everything else waits in the queue (64 max, oldest dropped,
  // only the newest presence kept); hello-ack is handled first, then the queue in arrival order.
  receive(raw) {
    if (this.dead) return;
    this.received += 1;
    const r = parseEnvelope(raw);
    if (!r.ok) { this.error(r.error.code, r.error.message, { ref: r.error.ref }); return; }
    const msg = r.msg;
    if (this.acked) { this.deliver(msg); return; }
    if (msg.type !== 'hello-ack') { this.enqueue(msg); return; }
    this.acked = true;
    this.deliver(msg);
    const queued = this.queue;
    this.queue = [];
    for (const m of queued) {
      if (this.dead) break;
      this.deliver(m);
    }
  }

  enqueue(msg) {
    if (msg.type === 'presence') {
      const i = this.queue.findIndex((m) => m.type === 'presence');
      if (i >= 0) { this.queue.splice(i, 1); this.dropped += 1; }
    }
    this.queue.push(msg);
    while (this.queue.length > QUEUE_LIMIT) { this.queue.shift(); this.dropped += 1; }
  }

  deliver(msg) {
    try {
      this.onMessage(msg);
    } catch (e) {
      this.error('internal', `handling ${msg.type} failed: ${errorText(e)}`, { ref: msg.id });
    }
  }
}
