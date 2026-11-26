"""Run the test suite in a Lua 5.1 runtime (same Lua version as the game).

Also fails if the mod writes any global variable, or reads a name that isn't
defined (a misspelling or a local used before it's declared), and if the built
script or the generated data block is out of date with its sources.
"""
import sys, pathlib, tempfile, importlib.util
from lupa import lua51

root = pathlib.Path(__file__).parent


def check_generated_files():
    """The shipped script must equal data + engine, and the data block must be
    what gen_data.py produces from exports/ (nobody edited it by hand)."""
    problems = []
    data = (root / "tools/data_block.lua").read_text()
    engine = (root / "src/engine.lua").read_text()
    built = (root / "script/campaign/mod/upgrade_all.lua").read_text()
    if built != data + "\n" + engine:
        problems.append("script/campaign/mod/upgrade_all.lua is out of date: run python3 build.py")
    spec = importlib.util.spec_from_file_location("gen_data", root / "tools/gen_data.py")
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp) / "data_block.lua"
        import io, contextlib
        with contextlib.redirect_stdout(io.StringIO()):
            gen.main(root / "exports", out)
        if out.read_text() != data:
            problems.append("tools/data_block.lua differs from gen_data.py output: "
                            "run python3 -I tools/gen_data.py exports tools/data_block.lua")
    for p in problems:
        print("FAIL", p)
    return not problems


generated_ok = check_generated_files()

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
sys.exit(1 if (failures or writes or missing or not generated_ok) else 0)
