"""Build the mod.

    python3 build.py                 script/campaign/mod/upgrade_all.lua only
    python3 build.py --pack          ... and dist/upgrade_all.pack (needs rpfm_cli)
    python3 build.py --pack --install  ... and copy the pack into the game's data folder

The script is generated data + blank line + engine. The pack is made with
rpfm_cli (cargo install rpfm_cli) as a *movie* pack: the macOS launcher does
not manage local packs, and movie packs load without being enabled. Revisit
the type if the mod is ever published.
"""
import argparse
import os
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).parent
SCRIPT = root / "script/campaign/mod/upgrade_all.lua"
PACK = root / "dist/upgrade_all.pack"
IN_PACK_DIR = "script/campaign/mod/"
PACK_TYPE = "movie"

GAME_DATA_DIRS = [
    pathlib.Path.home() / "Library/Application Support/Steam/steamapps/common/Total War WARHAMMER III/TotalWarhammer3Data/data",
    pathlib.Path("C:/Program Files (x86)/Steam/steamapps/common/Total War WARHAMMER III/data"),
]


def build_script():
    data = (root / "tools/data_block.lua").read_text()
    engine = (root / "src/engine.lua").read_text()
    SCRIPT.write_text(data + "\n" + engine)
    print(f"built {SCRIPT.relative_to(root)}: {len(SCRIPT.read_text().splitlines())} lines")


def rpfm(*args):
    cli = shutil.which("rpfm_cli")
    if not cli:
        sys.exit("rpfm_cli not found: install with `cargo install rpfm_cli` "
                 "(or download it from https://github.com/Frodo45127/rpfm/releases)")
    r = subprocess.run([cli, "--game", "warhammer_3", "pack", *args], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"rpfm_cli {' '.join(args)} failed:\n{r.stdout}{r.stderr}")
    return r.stdout


def build_pack():
    PACK.parent.mkdir(exist_ok=True)
    if PACK.exists():
        PACK.unlink()
    rpfm("create", "--pack-path", str(PACK))
    rpfm("add", "--pack-path", str(PACK), "--file-path", f"{SCRIPT};{IN_PACK_DIR}")
    rpfm("set-file-type", "--pack-path", str(PACK), "--file-type", PACK_TYPE)
    listed = rpfm("list", "--pack-path", str(PACK))
    expected = IN_PACK_DIR + SCRIPT.name
    if expected not in listed:
        sys.exit(f"pack does not contain {expected}:\n{listed}")
    print(f"built {PACK.relative_to(root)} ({PACK_TYPE} pack, {PACK.stat().st_size} bytes)")


def install_pack():
    target = os.environ.get("WH3_DATA_DIR")
    dirs = [pathlib.Path(target)] if target else GAME_DATA_DIRS
    for d in dirs:
        if d.is_dir():
            shutil.copy2(PACK, d / PACK.name)
            print(f"installed to {d / PACK.name}")
            return
    sys.exit("game data folder not found; set WH3_DATA_DIR to the game's data folder")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pack", action="store_true", help="also build dist/upgrade_all.pack with rpfm_cli")
    ap.add_argument("--install", action="store_true", help="copy the pack into the game's data folder (implies --pack)")
    a = ap.parse_args()
    build_script()
    if a.pack or a.install:
        build_pack()
    if a.install:
        install_pack()
