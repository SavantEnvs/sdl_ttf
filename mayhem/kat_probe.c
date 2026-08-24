/*
 * mayhem/kat_probe.c — known-answer probe for mayhem/test.sh.
 *
 * SDL_ttf ships no automated unit-test suite of its own (its `examples/` are interactive GUI
 * apps that need a display, e.g. examples/showfont.c / examples/testapp.c). So this is a small,
 * dedicated, dynamically-linked KAT binary: open a real font (mayhem/kat/Tuffy.ttf) via the same
 * memory-based TTF_OpenFontIO() API the fuzz harness uses, and assert exact values pulled from
 * the font's own metrics tables (hhea/OS2 scaled by FreeType, plus the name table) — NOT
 * hinting/rasterization output, which can be sensitive to FreeType minor-version/subpixel
 * settings. A neutered/no-op SDL_ttf (e.g. an `exit(0)` patch, or TTF_OpenFontIO always
 * returning NULL) fails every assertion below.
 *
 * Built by mayhem/build.sh with the project's NORMAL (unsanitized) flags against the SAME
 * source this repo ships (src/SDL_ttf.c + system libfreetype), so it is an honest, dynamically
 * linked functional oracle: LD_PRELOAD sabotage of the built binary cannot hide behind a
 * statically-linked runtime.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>

static int g_failed = 0;

#define CHECK(desc, cond) do { \
        if (cond) { printf("  ok   - %s\n", desc); } \
        else      { printf("  FAIL - %s\n", desc); g_failed++; } \
    } while (0)

static unsigned char *read_file(const char *path, size_t *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "kat_probe: cannot open %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc((size_t)sz);
    if (!buf || fread(buf, 1, (size_t)sz, f) != (size_t)sz) { fprintf(stderr, "kat_probe: read failed\n"); exit(1); }
    fclose(f);
    *out_size = (size_t)sz;
    return buf;
}

int main(int argc, char **argv) {
    const char *font_path = (argc > 1) ? argv[1] : "mayhem/kat/Tuffy.ttf";

    CHECK("TTF_Init", TTF_Init());

    size_t font_size = 0;
    unsigned char *font_bytes = read_file(font_path, &font_size);
    CHECK("font file non-empty", font_size > 1000);

    SDL_IOStream *io = SDL_IOFromConstMem(font_bytes, font_size);
    CHECK("SDL_IOFromConstMem", io != NULL);

    TTF_Font *font = TTF_OpenFontIO(io, true, 24.0f);
    CHECK("TTF_OpenFontIO opens Tuffy.ttf @ 24pt", font != NULL);
    if (!font) {
        printf("kat_probe: cannot continue without a font, failed=%d\n", g_failed + 1);
        return 1;
    }

    const char *family = TTF_GetFontFamilyName(font);
    CHECK("family name is exactly \"Tuffy\"", family != NULL && strcmp(family, "Tuffy") == 0);

    /* hhea-table-derived metrics, scaled to 24pt: stable across FreeType versions (pure integer
     * scaling of the font's own units_per_em, no hinting/rasterization involved). */
    int height  = TTF_GetFontHeight(font);
    int ascent  = TTF_GetFontAscent(font);
    int descent = TTF_GetFontDescent(font);
    printf("  -    height=%d ascent=%d descent=%d\n", height, ascent, descent);
    CHECK("TTF_GetFontHeight == 29",  height == 29);
    CHECK("TTF_GetFontAscent == 24",  ascent == 24);
    CHECK("TTF_GetFontDescent == -5", descent == -5);

    /* hmtx-table-derived glyph advance for 'A': also pure metrics, not rasterization. */
    int minx, maxx, miny, maxy, advance;
    int got = TTF_GetGlyphMetrics(font, 'A', &minx, &maxx, &miny, &maxy, &advance);
    printf("  -    'A' advance=%d\n", advance);
    CHECK("TTF_GetGlyphMetrics('A') succeeds", got);
    CHECK("'A' advance == 15", advance == 15);

    int w = -1, h = -1;
    SDL_Color fg = { 255, 255, 255, 255 };
    got = TTF_GetStringSize(font, "AAAA", 0, &w, &h);
    printf("  -    \"AAAA\" size=%dx%d\n", w, h);
    CHECK("TTF_GetStringSize succeeds", got);
    CHECK("\"AAAA\" width == 4x 'A' advance (60)", w == 60);

    SDL_Surface *surface = TTF_RenderText_Blended(font, "AAAA", 0, fg);
    CHECK("TTF_RenderText_Blended produces a surface", surface != NULL);
    if (surface) {
        printf("  -    surface %dx%d format=%d\n", surface->w, surface->h, surface->format);
        CHECK("surface width matches TTF_GetStringSize width", surface->w == w);
        CHECK("surface height matches TTF_GetStringSize height", surface->h == h);
        /* The rendered glyph must actually have painted non-background pixels somewhere: a
         * neutered renderer that allocates a correctly-sized but blank/transparent surface would
         * pass the size checks above while producing nothing. */
        const SDL_PixelFormatDetails *fmt = SDL_GetPixelFormatDetails(surface->format);
        int any_opaque = 0;
        SDL_LockSurface(surface);
        for (int y = 0; y < surface->h && !any_opaque; y++) {
            const unsigned char *row = (const unsigned char *)surface->pixels + (size_t)y * surface->pitch;
            for (int x = 0; x < surface->w; x++) {
                Uint32 pixel;
                memcpy(&pixel, row + (size_t)x * fmt->bytes_per_pixel, fmt->bytes_per_pixel);
                Uint8 r, g, b, a;
                SDL_GetRGBA(pixel, fmt, NULL, &r, &g, &b, &a);
                if (a > 0) { any_opaque = 1; break; }
            }
        }
        SDL_UnlockSurface(surface);
        CHECK("rendered surface has at least one non-transparent pixel", any_opaque);
        SDL_DestroySurface(surface);
    }

    TTF_CloseFont(font);
    free(font_bytes);

    printf("kat_probe: failed=%d\n", g_failed);
    return g_failed == 0 ? 0 : 1;
}
