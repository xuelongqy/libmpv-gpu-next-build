// Exercise the real event handler without creating libmpv or Vulkan resources.
#include <SDL.h>
#undef main
#define main smoke_program_main
#include "smoke.c"
#undef main
#if defined(SDL_MAIN_NEEDED) || defined(SDL_MAIN_AVAILABLE)
#define main SDL_main
#endif

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    CHECK(SDL_Init(SDL_INIT_EVENTS) == 0);
    struct app a = {.compare_hdr = true};
    SDL_Event event = {.type = SDL_MOUSEBUTTONUP};
    event.button.button = SDL_BUTTON_RIGHT;
    CHECK(SDL_PushEvent(&event) == 1);
    pump(&a);
    CHECK(a.toggle_hdr);

    a.toggle_hdr = false;
    event.button.button = SDL_BUTTON_LEFT;
    CHECK(SDL_PushEvent(&event) == 1);
    pump(&a);
    CHECK(!a.toggle_hdr);

    a.compare_hdr = false;
    event.button.button = SDL_BUTTON_RIGHT;
    CHECK(SDL_PushEvent(&event) == 1);
    pump(&a);
    CHECK(!a.toggle_hdr);

    a.compare_hdr = true;
    event = (SDL_Event){.key = {.type = SDL_KEYDOWN,
                               .keysym = {.sym = SDLK_SPACE}}};
    CHECK(SDL_PushEvent(&event) == 1);
    pump(&a);
    CHECK(a.toggle_hdr);
    event.key.keysym.sym = SDLK_ESCAPE;
    CHECK(SDL_PushEvent(&event) == 1);
    pump(&a);
    CHECK(a.quit);
    SDL_Quit();
    puts("HDR_INPUT=PASS");
    return 0;
}
