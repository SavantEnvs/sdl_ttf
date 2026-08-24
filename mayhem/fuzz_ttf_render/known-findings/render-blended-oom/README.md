# TTF_RenderText_Blended(): unbounded allocation -> libFuzzer OOM

**Found during:** local fork-mode fuzz-smoke of `fuzz_ttf_render` (`-fork=4`, ~92s, seeded from
`mayhem/fuzz_ttf_render/testsuite/`), while validating this port before deploy.

**Repro:** `repro.bin` — replay with `/mayhem/fuzz_ttf_render-standalone repro.bin` (crashes with
an ASan allocation-size-too-big-style abort under `-rss_limit_mb`), or
`/mayhem/fuzz_ttf_render -rss_limit_mb=2560 -runs=1 repro.bin` against the fuzz binary.

**libFuzzer/ASan report (fork-mode job):**
```
SUMMARY: libFuzzer: out-of-memory
  ...
  #10 AllocateAlignedPixels src/SDL_ttf.c:1627:14
  #11 Create_Surface_Blended src/SDL_ttf.c:1753:19
  #12 TTF_Render_Internal src/SDL_ttf.c:3909:19
  #13 LLVMFuzzerTestOneInput mayhem/fuzz_ttf_render.c:78:28
```

**Cause:** `TTF_RenderText_Blended()` allocates an output `SDL_Surface` sized to fit the *entire*
rendered string (`width x height`, from `TTF_GetStringSize()`-equivalent layout). The harness
bounds point size to a modest 8-104pt range
(`ptsize = 8.0f + (param_byte % 96)` in `mayhem/fuzz_ttf_render.c`), but a font can still drive
the surface width up unboundedly via oversized `hmtx` advance-width values on the glyphs making up
the fixed harness string — SDL_ttf does not clamp or reject an implausible total layout width
before allocating the destination surface for it.

**Impact:** A crafted font can make a single `TTF_RenderText_Blended()` call request a very large
allocation, which is an OOM/DoS vector for any caller that renders untrusted-font-derived text
(e.g. a font preview tool) without its own bound on either point size or string layout width.

**Not guarded in the harness:** per PORTING.md's fuzzing guidance ("do NOT guard crashes or
OOMs... masking them with validation upstream does not have destroys the productivity we want"),
`mayhem/fuzz_ttf_render.c` intentionally does not clamp glyph/advance widths — this is a genuine
finding, not a harness bug, and is left live so future fuzzing keeps surfacing variants of it.

**Possible upstream fix (not applied — this is a finding, not a patch):** clamp/reject a
`TTF_RenderText_*` call whose computed total width or height exceeds some sane cap (SDL_ttf
already has precedent for rejecting implausible font/glyph parameters elsewhere in
`src/SDL_ttf.c`).
