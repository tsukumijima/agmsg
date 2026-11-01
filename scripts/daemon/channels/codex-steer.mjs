// Mid-turn delivery to a Codex thread (fork: tsukumijima/agmsg).
//
// `codex queue` hands the notice to Codex's own queue, which Codex reads only
// after the running turn ends, so a Codex seat busy in a long turn hears
// nothing until it finishes. Where the thread runs in the local app-server
// daemon (the Codex App and `codex --remote` on Linux keep their threads
// there), any client of the daemon's control socket can append input to the
// running turn with `turn/steer` (measured 2026-11-01 on codex-cli 0.163/0.166:
// a steer from a second connection reached the running turn's final answer).
//
// trySteerCodexTurn returns true only when the steer was accepted. Every other
// outcome -- no daemon socket, the thread idle, the turn ended between the
// check and the steer, any error or timeout -- returns false so the caller
// falls back to `codex queue`, which is still right for an idle thread.

import { randomBytes } from "node:crypto";
import { existsSync, realpathSync } from "node:fs";
import { connect } from "node:net";
import { join } from "node:path";

export function controlSocketPath(codexHome) {
  return join(codexHome, "app-server-control", "app-server-control.sock");
}

// A minimal WebSocket client over a Unix socket: the daemon speaks JSON-RPC in
// WebSocket text frames on its control socket.
function openConnection(socketPath, timeoutMs) {
  return new Promise((resolve, reject) => {
    const socket = connect({ path: socketPath });
    let buffer = Buffer.alloc(0);
    let upgraded = false;
    const waiters = [];
    const messages = [];
    const timer = setTimeout(() => fail(new Error("timeout")), timeoutMs);

    function fail(error) {
      clearTimeout(timer);
      socket.destroy();
      reject(error);
      for (const waiter of waiters.splice(0)) waiter.reject(error);
    }

    function send(message) {
      const payload = Buffer.from(JSON.stringify(message));
      const mask = randomBytes(4);
      let header;
      if (payload.length < 126) {
        header = Buffer.from([0x81, 0x80 | payload.length]);
      } else if (payload.length < 65536) {
        header = Buffer.alloc(4);
        header.writeUInt8(0x81, 0);
        header.writeUInt8(0x80 | 126, 1);
        header.writeUInt16BE(payload.length, 2);
      } else {
        header = Buffer.alloc(10);
        header.writeUInt8(0x81, 0);
        header.writeUInt8(0x80 | 127, 1);
        header.writeBigUInt64BE(BigInt(payload.length), 2);
      }
      const masked = Buffer.alloc(payload.length);
      for (let i = 0; i < payload.length; i++) masked[i] = payload[i] ^ mask[i % 4];
      socket.write(Buffer.concat([header, mask, masked]));
    }

    function parseFrames() {
      let text = "";
      for (;;) {
        if (buffer.length < 2) return;
        const first = buffer[0];
        let size = buffer[1] & 0x7f;
        let offset = 2;
        if (size === 126) {
          if (buffer.length < 4) return;
          size = buffer.readUInt16BE(2);
          offset = 4;
        } else if (size === 127) {
          if (buffer.length < 10) return;
          size = Number(buffer.readBigUInt64BE(2));
          offset = 10;
        }
        if (buffer.length < offset + size) return;
        const payload = buffer.subarray(offset, offset + size);
        buffer = buffer.subarray(offset + size);
        const opcode = first & 0x0f;
        if (opcode === 0x8) return fail(new Error("closed"));
        if (opcode === 0x9 || opcode === 0xa) continue;
        text += payload.toString("utf8");
        if (first & 0x80) {
          let message;
          try {
            message = JSON.parse(text);
          } catch {
            message = null;
          }
          text = "";
          if (!message) continue;
          const waiter = waiters.find((w) => w.id === message.id && !("method" in message));
          if (waiter) {
            waiters.splice(waiters.indexOf(waiter), 1);
            waiter.resolve(message);
          } else {
            messages.push(message);
          }
        }
      }
    }

    let nextId = 0;
    function request(method, params) {
      const id = ++nextId;
      return new Promise((resolveRequest, rejectRequest) => {
        waiters.push({ id, resolve: resolveRequest, reject: rejectRequest });
        send({ jsonrpc: "2.0", id, method, params });
      }).then((response) => {
        if (response.error) throw new Error(`${method}: ${JSON.stringify(response.error)}`);
        return response.result ?? {};
      });
    }

    socket.on("error", fail);
    socket.on("connect", () => {
      const key = randomBytes(16).toString("base64");
      socket.write(
        `GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
          `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
      );
    });
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!upgraded) {
        const end = buffer.indexOf("\r\n\r\n");
        if (end < 0) return;
        const statusLine = buffer.subarray(0, buffer.indexOf("\r\n")).toString();
        buffer = buffer.subarray(end + 4);
        if (!/ 101 /.test(statusLine)) return fail(new Error(`upgrade refused: ${statusLine}`));
        upgraded = true;
        resolve({
          request,
          notify: (method, params) => send({ jsonrpc: "2.0", method, params }),
          close: () => {
            clearTimeout(timer);
            socket.destroy();
          },
        });
      }
      parseFrames();
    });
  });
}

export async function trySteerCodexTurn({ codexHome, thread, message, timeoutMs, connectTo = openConnection }) {
  if (process.platform === "win32") return false;
  const socketPath = controlSocketPath(codexHome);
  if (!existsSync(socketPath)) return false;
  let connection;
  try {
    connection = await connectTo(realpathSync(socketPath), timeoutMs);
    await connection.request("initialize", { clientInfo: { name: "agmsgd-codex-steer", version: "1" } });
    connection.notify("initialized", {});
    const turns = await connection.request("thread/turns/list", { threadId: thread, sortDirection: "desc", limit: 1 });
    const latest = turns.data?.[0];
    if (!latest || latest.status !== "inProgress") return false;
    // A turn that ended between the check and the steer fails on expectedTurnId,
    // and the notice goes through `codex queue` instead.
    await connection.request("turn/steer", {
      threadId: thread,
      expectedTurnId: latest.id,
      input: [{ type: "text", text: message }],
    });
    return true;
  } catch {
    return false;
  } finally {
    connection?.close();
  }
}
