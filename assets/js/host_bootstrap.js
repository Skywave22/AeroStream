// Host-side bootstrap injected into every plugin context.
// The real body is added in Phase 3; this file exists from Phase 0 so the
// asset bundle path is stable.
globalThis.__aerostream = globalThis.__aerostream || { version: 1 };
