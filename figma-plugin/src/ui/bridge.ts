/** Typed request/response messaging with the plugin main thread. */
import type { MainRequests, MainToUi, RequestKind, UiToMain } from "../shared/messages";

type Pending = { resolve: (value: unknown) => void; reject: (error: Error) => void };

export class Bridge {
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private listener?: (message: MainToUi) => void;

  constructor() {
    window.addEventListener("message", (event: MessageEvent) => {
      const message = (event.data as { pluginMessage?: MainToUi } | undefined)?.pluginMessage;
      if (!message) return;
      if (message.type === "response") {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        if (message.ok) pending.resolve(message.result);
        else pending.reject(new Error(message.error));
        return;
      }
      this.listener?.(message);
    });
  }

  onMessage(listener: (message: MainToUi) => void): void {
    this.listener = listener;
  }

  send(message: UiToMain): void {
    parent.postMessage({ pluginMessage: message }, "*");
  }

  request<K extends RequestKind>(kind: K, params: MainRequests[K]["params"]): Promise<MainRequests[K]["result"]> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject });
      this.send({ type: "request", id, kind, params } as UiToMain);
    });
  }
}
