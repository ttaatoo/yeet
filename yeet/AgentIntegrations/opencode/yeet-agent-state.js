// Managed by Yeet. Re-enabling AI replaces this integration.
// YEET_INTEGRATION_ID=opencode
// YEET_INTEGRATION_VERSION=2

import net from "node:net";

const socketPath = process.env.YEET_AUTOMATION_SOCKET;
const token = process.env.YEET_AUTOMATION_TOKEN;
const terminalID = process.env.YEET_TERMINAL_ID;
let requestSequence = Date.now() * 1000;
let requestChain = Promise.resolve();
let lastReportKey;

function enabled() {
  return process.env.YEET_AUTOMATION === "1"
    && !!socketPath
    && !!token
    && !!terminalID;
}

// OpenCode event payloads vary by release: some carry the session object,
// some only its id, some neither. Yeet resumes only when an id is present.
function sessionIDFrom(value) {
  if (!value) return undefined;
  const direct = value.sessionID ?? value.session_id;
  if (typeof direct === "string" && direct) return direct;
  const session = value.session ?? value.info;
  if (typeof session === "string") return session;
  const nested = session && typeof session === "object" ? session.id : undefined;
  return typeof nested === "string" && nested ? nested : undefined;
}

function report(state, reason, sessionID) {
  const key = `${state}|${sessionID ?? ""}`;
  if (key === lastReportKey) return Promise.resolve();
  lastReportKey = key;
  const pending = requestChain.then(() => reportOnce(state, reason, sessionID));
  requestChain = pending.catch(() => {});
  return pending;
}

function reportOnce(state, reason, sessionID) {
  if (!enabled()) return Promise.resolve();

  requestSequence += 1;
  const params = {
    state,
    reason: reason ?? `OpenCode lifecycle: ${state}`,
  };
  if (sessionID) params.sessionID = sessionID;
  const request = {
    version: 1,
    id: `yeet:opencode:${requestSequence}`,
    method: "agent.report",
    token,
    terminalID,
    params,
  };

  return new Promise((resolve) => {
    const socket = net.createConnection(socketPath);
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      socket.destroy();
      resolve();
    };
    socket.setTimeout(750, finish);
    socket.on("connect", () => socket.write(`${JSON.stringify(request)}\n`));
    socket.on("data", finish);
    socket.on("error", finish);
    socket.on("end", finish);
    socket.on("close", finish);
  });
}

function stateFromStatus(status) {
  const value = typeof status === "string" ? status : status?.type;
  switch (value?.toLowerCase()) {
    case "idle": return "idle";
    case "active":
    case "busy":
    case "pending":
    case "retry":
    case "running":
    case "streaming":
    case "working": return "working";
    default: return undefined;
  }
}

export const YeetAgentStatePlugin = async () => {
  if (!enabled()) return {};

  return {
    "chat.message": async (payload) => {
      const id = sessionIDFrom(payload?.message) ?? sessionIDFrom(payload);
      await report("working", undefined, id);
    },
    event: async ({ event }) => {
      const type = event?.type;
      const properties = event?.properties ?? {};
      const sessionID = sessionIDFrom(properties);
      switch (type) {
        case "session.status": {
          const state = stateFromStatus(properties.status);
          if (state) await report(state, undefined, sessionID);
          break;
        }
        case "tool.execute.before":
        case "tool.execute.after":
        case "permission.replied":
        case "question.replied":
        case "question.rejected":
        case "session.compacted":
          await report("working", undefined, sessionID);
          break;
        case "permission.asked":
        case "question.asked":
        case "session.error":
          await report("blocked", undefined, sessionID);
          break;
        case "session.idle":
          await report("idle", undefined, sessionID);
          break;
        default:
          break;
      }
    },
  };
};
