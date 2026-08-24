/*
 * mayhem/fuzz_ttf_render.c — libFuzzer harness for SDL_ttf.
 *
 * Treats the fuzzer input as a raw font blob (TTF/OTF/Type1/PCF/BDF/... anything FreeType's
 * vendored, sanitizer-instrumented `sfnt`/`truetype`/`cff`/`type1`/`cid`/`pcf`/`bdf`/`winfnt`/
 * `pfr`/`type42` modules recognize) and drives it through SDL_ttf's real memory-based API:
 * TTF_OpenFontIO() on an SDL_IOStream wrapping the input bytes, a handful of read-only metadata
 * queries, then TTF_RenderText_Blended() of a short fixed string. No filesystem I/O, no SDL video
 * subsystem needed (TTF_Init()/font parsing/software glyph rasterization work headless).
 *
 * The first byte of the input selects style/outline/hinting so those code paths get fuzzed too;
 * the rest of the bytes are the font blob. This costs nothing extra to wire (deterministic, no
 * source of nondeterminism) and reaches SDL_ttf's synth-bold/synth-italic/outline-stroke paths
 * that a byte-for-byte-untouched font blob would never exercise.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>

static int g_ttf_ready = 0;

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc; (void)argv;
    /* No SDL video/audio subsystem needed: TTF_Init() only touches FreeType + a mutex, and
     * TTF_RenderText_* produces a plain SDL_Surface via software rasterization. */
    g_ttf_ready = TTF_Init();
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!g_ttf_ready || size < 2) {
        return 0;
    }

    uint8_t style_byte = data[0];
    uint8_t param_byte = data[1];
    const uint8_t *font_bytes = data + 2;
    size_t font_size = size - 2;

    SDL_IOStream *io = SDL_IOFromConstMem(font_bytes, font_size);
    if (!io) {
        return 0;
    }

    /* ptsize in a plausible, bounded range so we don't spend the whole run on absurd rasterizer
     * sizes; TTF_OpenFontIO itself validates/rejects out-of-range sizes internally too. */
    float ptsize = 8.0f + (float)(param_byte % 96);

    /* closeio=true: TTF_CloseFont() (or a failed open) closes/frees the IOStream for us. */
    TTF_Font *font = TTF_OpenFontIO(io, true, ptsize);
    if (!font) {
        return 0;
    }

    TTF_FontStyleFlags style = 0;
    if (style_byte & 0x01) style |= TTF_STYLE_BOLD;
    if (style_byte & 0x02) style |= TTF_STYLE_ITALIC;
    if (style_byte & 0x04) style |= TTF_STYLE_UNDERLINE;
    if (style_byte & 0x08) style |= TTF_STYLE_STRIKETHROUGH;
    TTF_SetFontStyle(font, style);
    TTF_SetFontOutline(font, style_byte % 4);
    TTF_SetFontHinting(font, (style_byte >> 4) % 5);
    TTF_SetFontKerning(font, (style_byte & 0x10) != 0);

    /* Touch a few read-only metadata accessors (cheap extra surface, no new inputs needed). */
    (void)TTF_GetFontHeight(font);
    (void)TTF_GetFontAscent(font);
    (void)TTF_GetFontDescent(font);
    (void)TTF_GetFontFamilyName(font);
    (void)TTF_GetFontStyleName(font);
    (void)TTF_FontIsFixedWidth(font);

    static const char text[] = "The quick brown fox jumps 0123 \xc3\xa9\xc3\xbc!";
    SDL_Color fg = { 255, 255, 255, 255 };
    SDL_Surface *surface = TTF_RenderText_Blended(font, text, strlen(text), fg);
    if (surface) {
        SDL_DestroySurface(surface);
    }

    /* Also exercise per-glyph metrics + individual glyph rendering for a small character set. */
    static const Uint32 chars[] = { 'A', 'g', '@', 0x00e9 /* e-acute */, 0x4e2d /* CJK */ };
    for (size_t i = 0; i < SDL_arraysize(chars); i++) {
        int minx, maxx, miny, maxy, advance;
        (void)TTF_GetGlyphMetrics(font, chars[i], &minx, &maxx, &miny, &maxy, &advance);
        SDL_Surface *g = TTF_RenderGlyph_Blended(font, chars[i], fg);
        if (g) {
            SDL_DestroySurface(g);
        }
    }

    TTF_CloseFont(font);
    return 0;
}
