"""Run the test suite in a Lua 5.1 runtime (same Lua version as the game).

Also fails if the mod writes any global variable, or reads a name that isn't
defined (a misspelling or a local used before it's declared).
"""
import sys, pathlib
from lupa import lua51

root = pathlib.Path(__file__).parent
L = lua51.LuaRuntime()
L.globals().SCRIPT = str(root / "script/campaign/mod/upgrade_all.lua")
L.execute('''
GLOBAL_WRITES, GLOBAL_MISSING = {}, {}
local real_loadfile = loadfile
function loadfile(path)
  local f = assert(real_loadfile(path))
  if path == SCRIPT then
    setfenv(f, setmetatable({}, {
      __index = function(_, k) local v = _G[k]; if v == nil then GLOBAL_MISSING[tostring(k)] = true end; return v end,
      __newindex = function(_, k, v) GLOBAL_WRITES[tostring(k)] = true; rawset(_G, k, v) end }))
  end
  return f
end
''')
L.execute((root / "tests/test_upgrade_all.lua").read_text())

failures = L.globals().TEST_FAILURES
writes = sorted(L.globals().GLOBAL_WRITES.keys())
missing = sorted(L.globals().GLOBAL_MISSING.keys())
if writes:
    print("FAIL mod writes globals:", ", ".join(writes))
if missing:
    print("FAIL mod reads undefined names:", ", ".join(missing))
sys.exit(1 if (failures or writes or missing) else 0)
