// One JSON line per event on stdout — CloudWatch and Cloud Logging both parse it
// without an agent. Alerts additionally go to an optional webhook (Slack-compatible).

type Level = "debug" | "info" | "warn" | "error";

const LEVELS: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };
const minLevel = LEVELS[(process.env.LOG_LEVEL as Level) ?? "info"] ?? LEVELS.info;

let context: Record<string, unknown> = {};

export function setLogContext(ctx: Record<string, unknown>): void {
  context = { ...context, ...ctx };
}

function emit(level: Level, msg: string, fields?: Record<string, unknown>): void {
  if (LEVELS[level] < minLevel) return;
  const line = JSON.stringify(
    { ts: new Date().toISOString(), level, msg, ...context, ...fields },
    (_k, v) => (typeof v === "bigint" ? v.toString() : v),
  );
  (level === "error" || level === "warn" ? process.stderr : process.stdout).write(line + "\n");
}

export const log = {
  debug: (msg: string, f?: Record<string, unknown>) => emit("debug", msg, f),
  info: (msg: string, f?: Record<string, unknown>) => emit("info", msg, f),
  warn: (msg: string, f?: Record<string, unknown>) => emit("warn", msg, f),
  error: (msg: string, f?: Record<string, unknown>) => emit("error", msg, f),
};

let webhookUrl: string | undefined;
const lastAlertAt = new Map<string, number>();
const ALERT_DEDUPE_MS = 30 * 60_000;

export function configureAlerts(url: string | undefined): void {
  webhookUrl = url;
}

/**
 * Log at error level and post to the webhook. Alerts with the same key are
 * rate-limited so a persistently failing job does not flood the channel.
 */
export async function alert(key: string, msg: string, fields?: Record<string, unknown>): Promise<void> {
  emit("error", msg, { alert: key, ...fields });
  if (!webhookUrl) return;
  const now = Date.now();
  if (now - (lastAlertAt.get(key) ?? 0) < ALERT_DEDUPE_MS) return;
  lastAlertAt.set(key, now);
  const text = `[multyr-keeper ${context.instance ?? ""}/${context.network ?? ""}] ${msg}` +
    (fields ? `\n${JSON.stringify(fields, (_k, v) => (typeof v === "bigint" ? v.toString() : v))}` : "");
  try {
    await fetch(webhookUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      // `text` for Slack/Mattermost, `content` for Discord.
      body: JSON.stringify({ text, content: text.slice(0, 1900) }),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (e) {
    emit("warn", "alert webhook failed", { error: String(e) });
  }
}
