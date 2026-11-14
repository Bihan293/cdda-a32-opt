#!/usr/bin/env bash
# Pure performance patches for Cataclysm-DDA.
#
# These changes do NOT alter world generation, balance, NPC counts, the reality
# bubble, animations, sound, controls or any default gameplay option.
#
# Usage:
#   cd /path/to/Cataclysm-DDA
#   bash /path/to/scripts/apply_optimizations.sh
set -euo pipefail

SRC="${CDDA_DIR:-$PWD}"

if [[ ! -f "$SRC/src/sdltiles.cpp" || ! -f "$SRC/android/app/build.gradle" ]]; then
    echo "ERROR: $SRC does not look like a Cataclysm-DDA checkout" >&2
    exit 1
fi

python3 - "$SRC" <<'PY'
import pathlib
import sys

src = pathlib.Path(sys.argv[1])

def read(rel):
    return (src / rel).read_text(encoding="utf-8")

def write(rel, data):
    (src / rel).write_text(data, encoding="utf-8")

# ---------------------------------------------------------------------------
# 1. Do not present a frame when nothing has changed.
#
# The game currently calls refresh_display() from several places even when no
# UI redraw happened (the 10 Hz input poll during activities is the worst one).
# That clears and re-copies the whole screen and calls SDL_RenderPresent for an
# identical image. On a Helio G80 this is pure waste. needupdate is set by
# ui_manager::redraw(), every touch/key event and every renderer recovery, so
# skipping the present cannot hide a real visual change.
# ---------------------------------------------------------------------------
sdl = read("src/sdltiles.cpp")
old = """void refresh_display()
{
    needupdate = false;
    lastupdate = GetTicks();

    if( test_mode ) {
        return;
    }

    if( !present_gate() ) {
        // skip whole present, it will retry after next drain
        return;
    }

#if defined(SDL_SOUND)
    sound_backend::poll();
#endif
"""
new = """void refresh_display()
{
    lastupdate = GetTicks();

    if( test_mode ) {
        return;
    }

#if defined(SDL_SOUND)
    sound_backend::poll();
#endif

    // Nothing has asked for a repaint. Presenting the same buffer again costs
    // a full ClearScreen + RenderCopy + RenderPresent on Android.
    if( !needupdate ) {
        return;
    }
    needupdate = false;

    if( !present_gate() ) {
        // skip whole present, it will retry after next drain
        return;
    }
"""
if old not in sdl:
    raise SystemExit("could not find refresh_display prologue")
sdl = sdl.replace(old, new, 1)
write("src/sdltiles.cpp", sdl)

# ---------------------------------------------------------------------------
# 2. During sleep, the 10 Hz key-blocking path was presenting a frame without
#    any UI change. The sleep progress popup is still redrawn by
#    game::handle_progress_ui(); input is still pumped, so waking up works.
# ---------------------------------------------------------------------------
turn = read("src/do_turn.cpp")
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

# The progress popup does not need to be rebuilt every in-game minute while
# sleeping/reading/crafting. Five in-game minutes is still ~5 real seconds.
old = "std::min( 1_minutes, wait_refresh_rate )"
if old not in turn:
    raise SystemExit("could not find progress UI refresh interval")
turn = turn.replace(old, "std::min( 5_minutes, wait_refresh_rate )", 1)
write("src/do_turn.cpp", turn)

# ---------------------------------------------------------------------------
# 3. Android release build: upstream uses -Os -g. Use -O3, drop debug symbols,
#    and tune for the A32's Cortex-A75/A55 cluster. Same code, same behaviour.
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
# 4. Large heap. This does not change gameplay; it only lets the process keep
#    the tile atlas and a busy save in memory on a 4 GB phone.
# ---------------------------------------------------------------------------
manifest_rel = "android/app/src/main/AndroidManifest.xml"
manifest = read(manifest_rel)
old = 'android:allowBackup="true"'
if old not in manifest:
    raise SystemExit("could not find allowBackup in manifest")
manifest = manifest.replace(old, old + '\n        android:largeHeap="true"', 1)
write(manifest_rel, manifest)

print("Applied pure performance patches: -O3, no debug symbols, "
      "unchanged-frame present skip, sleep render throttle, largeHeap")
PY
