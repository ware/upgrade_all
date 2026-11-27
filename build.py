"""Build the mod.

    python3 build.py                 script/campaign/mod/upgrade_all.lua only
    python3 build.py --pack          ... and dist/upgrade_all.pack (needs rpfm_cli)
    python3 build.py --install       ... and copy the pack into the game's data folder
    python3 build.py --pack --output ~/Desktop/upgrade_all.pack
    python3 build.py --install --data-dir "D:/SteamLibrary/steamapps/common/Total War WARHAMMER III/data"

Where --install puts the pack, first match wins:
    --data-dir PATH, then $WH3_DATA_DIR, then the usual Steam folders for
    macOS, Windows and Linux (Proton), listed in GAME_DATA_DIRS.

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

HOME = pathlib.Path.home()
GAME_DATA_DIRS = {
    "darwin": [
        HOME / "Library/Application Support/Steam/steamapps/common/Total War WARHAMMER III/TotalWarhammer3Data/data",
    ],
    "win32": [
        pathlib.Path("C:/Program Files (x86)/Steam/steamapps/common/Total War WARHAMMER III/data"),
        pathlib.Path("C:/Program Files/Steam/steamapps/common/Total War WARHAMMER III/data"),
    ],
    "linux": [
        HOME / ".steam/steam/steamapps/common/Total War WARHAMMER III/data",
        HOME / ".local/share/Steam/steamapps/common/Total War WARHAMMER III/data",
        HOME / ".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/Total War WARHAMMER III/data",
    ],
}


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


def build_pack(pack):
    pack = pathlib.Path(pack).expanduser().resolve()
    pack.parent.mkdir(parents=True, exist_ok=True)
    if pack.exists():
        pack.unlink()
    rpfm("create", "--pack-path", str(pack))
    rpfm("add", "--pack-path", str(pack), "--file-path", f"{SCRIPT};{IN_PACK_DIR}")
    rpfm("set-file-type", "--pack-path", str(pack), "--file-type", PACK_TYPE)
    listed = rpfm("list", "--pack-path", str(pack))
    expected = IN_PACK_DIR + SCRIPT.name
    if expected not in listed:
        sys.exit(f"pack does not contain {expected}:\n{listed}")
    shown = pack.relative_to(root) if pack.is_relative_to(root) else pack
    print(f"built {shown} ({PACK_TYPE} pack, {pack.stat().st_size} bytes)")
    return pack


def game_data_dir(explicit):
    """The game's data folder: --data-dir, then $WH3_DATA_DIR, then the platform defaults."""
    for candidate in [explicit, os.environ.get("WH3_DATA_DIR")]:
        if candidate:
            d = pathlib.Path(candidate).expanduser()
            if d.is_dir():
                return d
            sys.exit(f"{d} is not a folder")
    for d in GAME_DATA_DIRS.get(sys.platform, []):
        if d.is_dir():
            return d
    sys.exit(f"game data folder not found for {sys.platform}; pass --data-dir or set WH3_DATA_DIR")


def install_pack(pack, data_dir):
    d = game_data_dir(data_dir)
    shutil.copy2(pack, d / pack.name)
    print(f"installed to {d / pack.name}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pack", action="store_true", help="also build the .pack with rpfm_cli")
    ap.add_argument("--install", action="store_true", help="copy the pack into the game's data folder (implies --pack)")
    ap.add_argument("--output", metavar="PATH", default=str(PACK), help=f"where to write the pack (default {PACK.relative_to(root)})")
    ap.add_argument("--data-dir", metavar="PATH", help="the game's data folder for --install (default: $WH3_DATA_DIR, then the usual Steam folders)")
    a = ap.parse_args()
    build_script()
    if a.pack or a.install:
        pack = build_pack(a.output)
    if a.install:
        install_pack(pack, a.data_dir)
