// Read-only display evidence for the independent Windows HDR smoke client.
#define WINVER 0x0A00
#define _WIN32_WINNT 0x0A00
#include <sdkddkver.h>
#undef NTDDI_VERSION
#define NTDDI_VERSION NTDDI_WIN11_GA
#include <windows.h>
#include <SDL.h>
#include <SDL_syswm.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

bool smoke_windows_display(SDL_Window *window, bool hdr)
{
    SDL_SysWMinfo wm;
    SDL_VERSION(&wm.version);
    if (!SDL_GetWindowWMInfo(window, &wm)) return false;
    MONITORINFOEXW monitor = {.cbSize = sizeof(monitor)};
    if (!GetMonitorInfoW(MonitorFromWindow(wm.info.win.window,
                            MONITOR_DEFAULTTONEAREST), (MONITORINFO *)&monitor))
        return false;
    DISPLAYCONFIG_PATH_INFO *paths = NULL;
    DISPLAYCONFIG_MODE_INFO *modes = NULL;
    UINT32 num_paths = 0, num_modes = 0;
    LONG status = ERROR_INSUFFICIENT_BUFFER;
    for (int attempt = 0; attempt < 3 && status == ERROR_INSUFFICIENT_BUFFER; attempt++) {
        free(paths); free(modes);
        paths = NULL; modes = NULL;
        status = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &num_paths, &num_modes);
        if (status != ERROR_SUCCESS) break;
        paths = calloc(num_paths, sizeof(*paths));
        modes = calloc(num_modes, sizeof(*modes));
        if (!paths || !modes) { status = ERROR_OUTOFMEMORY; break; }
        status = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &num_paths, paths,
                                     &num_modes, modes, NULL);
    }
    bool available = false;
    fprintf(stderr, "WIN_DISPLAY_QUERY=%ld GDI=%ls BOUNDS=%ld,%ld,%ld,%ld\n",
        status, monitor.szDevice, monitor.rcMonitor.left, monitor.rcMonitor.top,
        monitor.rcMonitor.right, monitor.rcMonitor.bottom);
    for (UINT32 i = 0; status == ERROR_SUCCESS && i < num_paths; i++) {
        DISPLAYCONFIG_SOURCE_DEVICE_NAME source = {.header = {
            .type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, .size = sizeof(source),
            .adapterId = paths[i].sourceInfo.adapterId, .id = paths[i].sourceInfo.id}};
        if (DisplayConfigGetDeviceInfo(&source.header) ||
            wcscmp(source.viewGdiDeviceName, monitor.szDevice)) continue;
        DISPLAYCONFIG_TARGET_DEVICE_NAME name = {.header = {
            .type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, .size = sizeof(name),
            .adapterId = paths[i].targetInfo.adapterId, .id = paths[i].targetInfo.id}};
        LONG name_status = DisplayConfigGetDeviceInfo(&name.header);
        DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2 info = {.header = {
            .type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO_2, .size = sizeof(info),
            .adapterId = paths[i].targetInfo.adapterId, .id = paths[i].targetInfo.id}};
        LONG color_status = DisplayConfigGetDeviceInfo(&info.header);
        DISPLAYCONFIG_SDR_WHITE_LEVEL white = {.header = {
            .type = DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL, .size = sizeof(white),
            .adapterId = paths[i].targetInfo.adapterId, .id = paths[i].targetInfo.id}};
        LONG white_status = DisplayConfigGetDeviceInfo(&white.header);
        fprintf(stderr, "WIN_DISPLAY_NAME_STATUS=%ld NAME=%ls TECHNOLOGY=%d\n",
            name_status, name.monitorFriendlyDeviceName, paths[i].targetInfo.outputTechnology);
        fprintf(stderr, "WIN_HDR_STATUS=%ld SUPPORTED=%u ENABLED=%u ACTIVE_MODE=%d BPC=%u\n",
            color_status, info.highDynamicRangeSupported, info.highDynamicRangeUserEnabled,
            info.activeColorMode, info.bitsPerColorChannel);
        fprintf(stderr, "WIN_SDR_WHITE_STATUS=%ld NITS=%.6f HDR_METADATA_SENT=0\n",
            white_status, white_status ? -1 : white.SDRWhiteLevel * 80.0 / 1000);
        available = !hdr || (!color_status && info.highDynamicRangeSupported &&
            info.highDynamicRangeUserEnabled && info.activeColorMode == DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR);
        break;
    }
    free(paths); free(modes);
    return available;
}
