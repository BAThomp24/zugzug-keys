/**
 * Minimal KV interface — vendored from zugzug.info/shared/src/kv.ts.
 *
 * wclLust.ts only needs the ZugzugKV shape (update-lustdata.ts feeds it an
 * in-memory Map-backed stub); the rest of the upstream module was
 * Cloudflare-worker plumbing that died with the website.
 */

export interface ZugzugKV {
  get(key: string, options?: { type: "text" }): Promise<string | null>;
  put(
    key: string,
    value: string,
    options?: { expirationTtl?: number },
  ): Promise<void>;
}
