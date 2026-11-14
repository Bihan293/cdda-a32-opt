#!/usr/bin/env bash
# Apply the A32 performance patches to a Cataclysm-DDA checkout.
#
# Usage:
#   cd /path/to/Cataclysm-DDA
#   bash /path/to/scripts/apply_optimizations.sh [MAPSIZE] [performance|balanced]
#
# The script is intentionally assertive: if an upstream file changes enough
# that a replacement no longer matches, it fails instead of silently doing
# nothing.
set -euo pipefail

SRC="${CDDA_DIR:-$PWD}"
BUBBLE="${1:-7}"
VARIANT="${2:-performance}"

if [[ ! -f "$SRC/src/options.cpp" || ! -f "$SRC/android/app/build.gradle" ]]; then
    echo "ERROR: $SRC does not look like a Cataclysm-DDA checkout" >&2
    exit 1
fi

python3 - "$SRC" "$BUBBLE" "$VARIANT" <<'PY'
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1])
bubble = int(sys.argv[2])
variant = sys.argv[3]
if bubble % 2 == 0 or bubble < 5 or bubble > 11:
    raise SystemExit(f"MAPSIZE must be an odd number between 5 and 11, got {bubble}")
if variant not in ("performance", "balanced"):
    raise SystemExit(f"unknown variant {variant!r}")

def read(rel):
    return (src / rel).read_text(encoding="utf-8")

def write(rel, data):
    (src / rel).write_text(data, encoding="utf-8")

def option_block(text, name):
    needle = f'add( "{name}"'
    start = text.find(needle)
    if start < 0:
        raise SystemExit(f"could not find option {name}")
    end = text.find(");", start)
    if end < 0:
        raise SystemExit(f"could not find end of option {name}")
    return start, end + 2

def set_bool_default(text, name, value):
    start, end = option_block(text, name)
    block = text[start:end]
    new_block, count = re.subn(r'(?m)^(\s+)true(?=,|\s*$)', rf'\g<1>{value}', block, count=1)
    if count != 1:
        raise SystemExit(f"could not find boolean default for {name}")
    return text[:start] + new_block + text[end:]

def set_exact_default(text, name, old, new):
    start, end = option_block(text, name)
    block = text[start:end]
    if old not in block:
        raise SystemExit(f"could not find {old!r} in option {name}")
    block = block.replace(old, new, 1)
    return text[:start] + block + text[end:]

# ---------------------------------------------------------------------------
# 1. Reality bubble. 11 -> 7 is 2.5x less simulated area. The visible screen
#    still fits, and ranged combat is capped at 36 tiles instead of 60.
# ---------------------------------------------------------------------------
scale = read("src/map_scale_constants.h")
old = "constexpr int MAPSIZE = 11;"
if old not in scale:
    raise SystemExit("could not find MAPSIZE")
scale = scale.replace(old, f"constexpr int MAPSIZE = {bubble};", 1)
write("src/map_scale_constants.h", scale)

# ---------------------------------------------------------------------------
# 2. Runtime defaults that remove work from the per-turn loop.
# ---------------------------------------------------------------------------
opts = read("src/options.cpp")

# Do not force a full redraw + present every single turn.
opts = set_bool_default(opts, "FORCE_REDRAW", "false")

# Animations cost a delay and a present per animation frame. Off by default;
# the player can turn them back on in Options > Graphics > Animation.
for name in (
    "ANIMATIONS",
    "ANIMATION_RAIN",
    "ANIMATION_PROJECTILES",
    "ANIMATION_SCT",
    "ANIMATION_SCT_USE_FONT",
):
    opts = set_bool_default(opts, name, "false")
opts = set_exact_default(opts, "ANIMATION_DELAY", "0, 100, 10", "0, 100, 0")

# Audio polling and mixing are measurable on a Helio G80.
opts = set_bool_default(opts, "SOUND_ENABLED", "false")

# Autosaves are a common source of hitches; do them much less often.
opts = set_exact_default(opts, "AUTOSAVE_TURNS", "10, 1000, 50", "10, 1000, 500")
opts = set_exact_default(opts, "AUTOSAVE_MINUTES", "0, 127, 5", "0, 127, 30")

# The default 16 px UI is tiny on a 720p 6.5" screen. Android's "auto" text
# size fits 80 columns, i.e. an 8 px glyph, across a 720 px short side.
# 12x24 gives ~60 columns: readable, and fewer cells to redraw.
opts = set_exact_default(opts, "ANDROID_TEXT_SIZE", 'text_sizes, "auto"', 'text_sizes, "12x24"')
opts = set_exact_default(opts, "FONT_SIZE", "8, 100, 16", "8, 100, 20")
opts = set_exact_default(opts, "MAP_FONT_SIZE", "8, 100, 16", "8, 100, 20")
opts = set_exact_default(opts, "OVERMAP_FONT_SIZE", "8, 100, 16", "8, 100, 20")

# Make the on-screen controls easier to hit without changing the layout.
opts = set_exact_default(opts, "ANDROID_VIRTUAL_JOYSTICK_OPACITY", "0, 100, 20", "0, 100, 35")
opts = set_exact_default(opts, "ANDROID_JOYSTICK_SCALE", "0.25f, 4.0f, 1.0f", "0.25f, 4.0f, 1.30f")

# Never silently fall back to the software renderer on this device.
opts = set_exact_default(
    opts,
    "SOFTWARE_RENDERING",
    'android_get_default_setting( "Software rendering", false )',
    "false",
)
write("src/options.cpp", opts)

# ---------------------------------------------------------------------------
# 3. While sleeping, do not present a frame 10 times per second. The progress
#    popup still redraws every 5 in-game minutes, and input is still pumped.
# ---------------------------------------------------------------------------
turn = read("src/do_turn.cpp")
old = "std::min( 1_minutes, wait_refresh_rate )"
if old not in turn:
    raise SystemExit("could not find progress UI refresh interval")
turn = turn.replace(old, "std::min( 5_minutes, wait_refresh_rate )", 1)

old = """    } else {
        refresh_display();
        inp_mngr.pump_events();
    }
}"""
new = """    } else {
        if( !u.has_effect( effect_sleep ) ) {
            refresh_display();
        }
        inp_mngr.pump_events();
    }
}"""
if old not in turn:
    raise SystemExit("could not find handle_key_blocking_activity tail")
turn = turn.replace(old, new, 1)
write("src/do_turn.cpp", turn)

# ---------------------------------------------------------------------------
# 4. World generation defaults: smaller, farther apart cities and far fewer
#    random NPCs. Existing worlds are unaffected; this only changes new ones.
# ---------------------------------------------------------------------------
region_rel = "data/json/region_settings/region_settings/regional_map_settings.json"
region = read(region_rel)
if variant == "balanced":
    city_size, city_spacing, npc_days = 6, 6, 14
else:
    city_size, city_spacing, npc_days = 4, 8, 30

needle = '    "type": "region_settings",\n    "id": "default",\n'
if needle not in region:
    raise SystemExit("could not find default region_settings block")
region = region.replace(
    needle,
    needle + f'    "npc_spawntime": {npc_days},\n',
    1,
)
old_city = '    "city_size": 8,\n    "city_spacing": 4,\n'
new_city = f'    "city_size": {city_size},\n    "city_spacing": {city_spacing},\n'
if old_city not in region:
    raise SystemExit("could not find default city settings")
region = region.replace(old_city, new_city, 1)
write(region_rel, region)

# ---------------------------------------------------------------------------
# 5. Android release build: the upstream file uses -Os -g. Use -O3, drop
#    debug symbols, and tune for the A32's Cortex-A75/A55 cluster.
# ---------------------------------------------------------------------------
gradle_rel = "android/app/build.gradle"
gradle = read(gradle_rel)
flags = ('"-DNDEBUG", "-DRELEASE", "-O3", "-fno-semantic-interposition", '
         '"-march=armv8-a", "-mtune=cortex-a75", '
         '"-ffunction-sections", "-fdata-sections"')
old_c = 'cFlags "-DNDEBUG", "-DRELEASE", "-Os", "-g"'
old_cpp = 'cppFlags "-DNDEBUG", "-DRELEASE", "-Os", "-g"'
if old_c not in gradle or old_cpp not in gradle:
    raise SystemExit("could not find release compiler flags")
gradle = gradle.replace(old_c, f"cFlags {flags}", 1)
gradle = gradle.replace(old_cpp, f"cppFlags {flags}", 1)
if "debugSymbolLevel 'SYMBOL_TABLE'" not in gradle:
    raise SystemExit("could not find debugSymbolLevel")
gradle = gradle.replace("debugSymbolLevel 'SYMBOL_TABLE'", "debugSymbolLevel 'NONE'", 1)
write(gradle_rel, gradle)

# ---------------------------------------------------------------------------
# 6. Give the Java heap/process room for the big UltiCa atlas on a 4 GB phone.
# ---------------------------------------------------------------------------
manifest_rel = "android/app/src/main/AndroidManifest.xml"
manifest = read(manifest_rel)
old = 'android:allowBackup="true"'
if old not in manifest:
    raise SystemExit("could not find allowBackup in manifest")
manifest = manifest.replace(old, old + '\n        android:largeHeap="true"', 1)
write(manifest_rel, manifest)

print(f"Applied: MAPSIZE={bubble}, variant={variant}, "
      f"city_size={city_size}, city_spacing={city_spacing}, npc_spawntime={npc_days}")
PY
