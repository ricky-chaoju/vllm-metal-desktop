// A stand-in for the engine's foreign native libraries (e.g. _paged_ops.so,
// libmlx.dylib): a small dylib that is ad-hoc signed (no Team ID), i.e. not
// signed by this app's developer team.
int poc_answer(void) { return 42; }
