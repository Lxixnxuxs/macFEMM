// fkn_headless_globals.cpp — Headless-only globals pulled out of fkn.cpp.
//
// The Windows build of fkn.cpp defines the CFknApp class and the `lua` global.
// In the headless build we skip CFknApp entirely (no MFC) but the math still
// references the `lua` global from fkn/prob{1,3}big.cpp. This translation
// unit is the minimum needed: define `lua`, open it before `old_main` runs,
// close it on exit.

#include "lua.h"
#include <cstdlib>

lua_State* lua = nullptr;

extern void lua_baselibopen(lua_State* L);
extern void lua_iolibopen(lua_State* L);
extern void lua_strlibopen(lua_State* L);
extern void lua_mathlibopen(lua_State* L);
extern void lua_dblibopen(lua_State* L);

static void fkn_lua_shutdown() {
    if (lua) {
        lua_close(lua);
        lua = nullptr;
    }
}

// Constructor runs before main(). This matches the order the Windows GUI
// establishes (CFknApp::InitInstance opens Lua before _beginthread(old_main)).
struct FknLuaInit {
    FknLuaInit() {
        lua = lua_open(4096);
        lua_baselibopen(lua);
        lua_strlibopen(lua);
        lua_mathlibopen(lua);
        lua_iolibopen(lua);
        std::atexit(fkn_lua_shutdown);
    }
};
static FknLuaInit fkn_lua_init_instance;
