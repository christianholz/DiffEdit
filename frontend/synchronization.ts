import { ChangeSet } from "@codemirror/state";
import type { DiffUpdate } from "./model";

type Invoke = <T>(command: string, args: Record<string, unknown>) => Promise<T>;

/** One writer per buffer. Ambiguous failures recover from a full snapshot,
 * never by replaying offsets against a possibly different native document. */
export class DocumentSync {
  private pending: ChangeSet | null = null;
  private flight: Promise<void> | null = null;
  private recovery = false;
  private reported = false;

  constructor(
    private readonly options: {
      path: string;
      version: () => number;
      text: () => string;
      invoke: Invoke;
      receive: (update: DiffUpdate, current: boolean) => void;
      fail: (error: unknown) => void;
    },
  ) {}

  enqueue(changes: ChangeSet) {
    this.pending = this.pending ? this.pending.compose(changes) : changes;
    queueMicrotask(
      () =>
        void this.flush().catch((error) => {
          if (!this.reported) {
            this.reported = true;
            this.options.fail(error);
          }
        }),
    );
  }

  private start(): Promise<void> {
    if (this.flight) return this.flight;
    this.flight = Promise.resolve()
      .then(async () => {
        while (this.pending || this.recovery) {
          const changes = this.pending;
          this.pending = null;
          const edits: { from: number; to: number; insert: string }[] = [];
          changes?.iterChanges((from, to, _f, _t, text) =>
            edits.push({ from, to, insert: text.toString() }),
          );
          try {
            let update: DiffUpdate;
            if (this.recovery) {
              this.pending = null;
              update = await this.options.invoke("sync_document", {
                path: this.options.path,
                text: this.options.text(),
              });
            } else {
              try {
                update = await this.options.invoke("edit_document", {
                  path: this.options.path,
                  version: this.options.version() + 1,
                  edits,
                });
              } catch {
                // Discard offset batches only when their complete replacement
                // snapshot has been captured, including edits made in flight.
                this.recovery = true;
                this.pending = null;
                update = await this.options.invoke("sync_document", {
                  path: this.options.path,
                  text: this.options.text(),
                });
              }
            }
            this.recovery = false;
            this.reported = false;
            this.options.receive(update, !this.pending);
          } catch (error) {
            this.recovery = true;
            throw error;
          }
        }
      })
      .finally(() => {
        this.flight = null;
      });
    return this.flight;
  }

  async flush() {
    // Explicit saves can retry recovery even when no further edits were made.
    do {
      await this.start();
    } while (this.pending || this.recovery);
  }
}

/** Pending opens share one identity; clearing invalidates old workspace loads. */
export class BufferStore<T> extends Map<string, T> {
  private loads = new Map<string, Promise<T>>();
  private generation = 0;
  load(path: string, create: () => Promise<T>): Promise<T> {
    if (this.has(path)) return Promise.resolve(this.get(path)!);
    const pending = this.loads.get(path);
    if (pending) return pending;
    const generation = this.generation;
    const request = create()
      .then((buffer) => {
        if (generation !== this.generation)
          throw Error("Workspace changed while opening file");
        this.set(path, buffer);
        return buffer;
      })
      .finally(() => {
        if (this.loads.get(path) === request) this.loads.delete(path);
      });
    this.loads.set(path, request);
    return request;
  }
  override clear() {
    this.generation++;
    this.loads.clear();
    super.clear();
  }
}
