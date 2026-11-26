"""Build script/campaign/mod/upgrade_all.lua = generated data + blank line + engine."""
import pathlib
root = pathlib.Path(__file__).parent
data = (root / "tools/data_block.lua").read_text()
engine = (root / "src/engine.lua").read_text()
out = root / "script/campaign/mod/upgrade_all.lua"
out.write_text(data + "\n" + engine)
print(f"built {out.relative_to(root)}: {len(out.read_text().splitlines())} lines")
