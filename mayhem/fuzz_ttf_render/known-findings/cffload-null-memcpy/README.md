# cffload.c: null pointer passed to memcpy() with declared-nonnull arg 2

**Found during:** local fork-mode fuzz-smoke of `fuzz_ttf_render` (`-fork=4`, ~92s, seeded from
`mayhem/fuzz_ttf_render/testsuite/`), while validating this port before deploy.

**Repro:** `repro.bin` — replay with `/mayhem/fuzz_ttf_render-standalone repro.bin` (or
`/mayhem/fuzz_ttf_render -runs=1 repro.bin` against the fuzz binary).

**UBSan report:**
```
external/freetype/src/cff/cffload.c:639:7: runtime error: null pointer passed as argument 2,
which is declared to never be null
/usr/include/string.h:44:28: note: nonnull attribute specified here
```

**Cause:** `cff_index_get_name()` (`src/cff/cffload.c`) reads an entry from a CFF font's Name
INDEX:

```c
error = cff_index_access_element( idx, element, &bytes, &byte_len );
if ( error )
    goto Exit;

if ( !FT_QALLOC( name, byte_len + 1 ) )
{
    FT_MEM_COPY( name, bytes, byte_len );   /* line 639 */
    name[byte_len] = 0;
}
```

For a Name INDEX entry of length 0, `cff_index_access_element()` can return `byte_len == 0` with
`bytes == NULL` (an empty/degenerate CFF INDEX entry — trivial to construct in a malformed OTF/CFF
font). `FT_MEM_COPY` expands to `memcpy(name, bytes, 0)`, i.e. `memcpy(dst, NULL, 0)`. Passing a
NULL pointer to `memcpy`'s `src` is undefined behavior per the C standard (both pointer args carry
an implicit `nonnull` contract regardless of length) even though every mainstream libc
implementation treats a zero-length copy as a no-op in practice.

**Impact:** Benign in practice (no observed memory-safety consequence — this is a strict-UB
technicality, not a read/write out of bounds), but it is real, upstream, and trivially fixable:

```c
if ( byte_len )
    FT_MEM_COPY( name, bytes, byte_len );
```

**Upstream:** `libsdl-org/freetype` (the SDL org's FreeType fork/submodule, tracking
`VER-2-13-3-SDL`), `src/cff/cffload.c`, `cff_index_get_name()`. Likely present in upstream
FreeType proper too (not SDL-specific code) — worth checking/reporting to `freetype/freetype`.

**Not disabled in build.sh:** left as a live finding (only `pointer-overflow`/`shift-base` are
relaxed in build.sh, for a different, floods-on-valid-input reason — see the comment there); this
one fires rarely enough (once in the whole local smoke run) to leave halting.
