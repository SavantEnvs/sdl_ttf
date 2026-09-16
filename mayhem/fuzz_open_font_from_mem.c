/* Fuzz harness: open a font from fuzzer-controlled memory and render text.
 *
 * Ported from the original mayhemheroes harness (fuzz/fuzz_open_font_from_mem.c,
 * SDL2_ttf API) to the SDL3_ttf API that upstream main now targets:
 *   SDL_RWFromMem      -> SDL_IOFromConstMem
 *   TTF_OpenFontRW     -> TTF_OpenFontIO
 *   TTF_RenderText_Solid(font, text, fg) -> TTF_RenderText_Solid(font, text, length, fg)
 *   SDL_FreeSurface    -> SDL_DestroySurface
 */
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>

#define PT_SIZE 12.0f

static bool lib_init = false;
static const SDL_Color color = { 255, 255, 255, 255 };

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (!lib_init) {
        if (!TTF_Init()) {
            return 0;
        }
        lib_init = true;
    }

    SDL_IOStream *src = SDL_IOFromConstMem(data, size);
    if (!src) {
        return 0;
    }

    /* closeio=true: the font (or a failed open) owns and closes the stream. */
    TTF_Font *font = TTF_OpenFontIO(src, true, PT_SIZE);
    if (font) {
        const char *text = "Fuzzing is fun";
        SDL_Surface *surface = TTF_RenderText_Solid(font, text, 0, color);
        if (surface) {
            SDL_DestroySurface(surface);
        }
        TTF_CloseFont(font);
    }

    return 0;
}
