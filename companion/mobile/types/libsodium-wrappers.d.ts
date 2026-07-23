// Minimal ambient declaration for the base `libsodium-wrappers` build, which
// ships no bundled types. Only used by the test/vector-generation Node path; the
// session core reaches it structurally via the `RawLibsodium` interface in
// src/core/sodium.ts, so we keep this deliberately loose.
declare module 'libsodium-wrappers' {
  interface Sodium {
    ready: Promise<void>;
    [fn: string]: unknown;
  }
  const sodium: Sodium;
  export default sodium;
}
