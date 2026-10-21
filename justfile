volume := "/Volumes/NICENANO"
# CONFIG_USB_DEVICE_PRODUCT in snippets/bootloader-on-1200-baud
product := "Sofle"
cache := env("XDG_CACHE_HOME", env("HOME") / ".cache") / "sofle-zmk"

# Incremental local build of one half: just build left|right|settings_reset
build side:
    #!/usr/bin/env -S nix develop . -c bash
    set -euo pipefail
    case "{{side}}" in
        left|right) shield="sofle_{{side}} nice_view_adapter nice_view_gem" snippet="bootloader-on-1200-baud" ;;
        settings_reset) shield="settings_reset" snippet="" ;;
        *) echo "unknown side: {{side}} (left, right, settings_reset)" >&2; exit 1 ;;
    esac

    root="{{cache}}/$(basename "$ZMK_WEST_DEPS" | cut -d- -f1)"
    ws="$root/workspace"
    build="$root/{{side}}"
    if [ ! -d "$ws" ]; then
        mkdir -p "$ws/.west"
        for dep in "$ZMK_WEST_DEPS"/*; do ln -s "$dep" "$ws/$(basename "$dep")"; done
        ln -s "$PWD/config" "$ws/config"
        printf '[manifest]\npath = config\nfile = west.yml\n' >"$ws/.west/config"
    fi

    export ZEPHYR_BASE="$ZMK_WEST_DEPS/zephyr"
    if [ ! -f "$build/build.ninja" ]; then
        modules=$(cd "$ws" && west list -f '{path}' | grep -vx -e config -e zephyr \
            | sed "s#^#$ZMK_WEST_DEPS/#" | paste -sd';' -)
        cmake -GNinja -S "$ZMK_WEST_DEPS/zmk/app" -B "$build" \
            -DZephyr_DIR="$ZEPHYR_BASE/share/zephyr-package/cmake" \
            -DBUILD_VERSION="$(<"$ZEPHYR_BASE/.git/HEAD")" \
            -DZEPHYR_MODULES="$modules" \
            -DBOARD=nice_nano//zmk \
            -DSHIELD="$shield" \
            ${snippet:+-DSNIPPET="$snippet"} \
            -DZMK_CONFIG="$PWD/config" \
            -DZMK_EXTRA_MODULES="$PWD" \
            >"$build.configure.log" 2>&1 \
            || { tail -40 "$build.configure.log" >&2; rm -rf "$build"; exit 1; }
    fi
    ninja -C "$build" | tail -1
    echo "$build/zephyr/zmk.uf2"

# Clean, reproducible build of both halves into ./result
nix-build:
    nix build .#firmware

# Flash one half: just flash left|right|settings_reset [local|ci]
flash side source="local":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{side}}" in
        left|right) pattern="sofle_{{side}} *.uf2" ;;
        settings_reset) pattern="settings_reset-*.uf2" ;;
        *) echo "unknown side: {{side}} (left, right, settings_reset)" >&2; exit 1 ;;
    esac

    case "{{source}}" in
        local)
            uf2=$(just build "{{side}}" | tail -1)
            [ -f "$uf2" ] || { echo "build did not produce $uf2" >&2; exit 1; }
            echo "firmware: $uf2"
            ;;
        ci)
            repo=$(git remote get-url origin | sed -E 's#/+$##; s#\.git$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')
            branch=$(git rev-parse --abbrev-ref HEAD)
            run=$(gh run list -R "$repo" -w build.yml -b "$branch" -s success -L 1 --json databaseId,headSha \
                --jq '.[0] | "\(.databaseId) \(.headSha[:7])"')
            [ -n "$run" ] || { echo "no successful build of $branch in $repo" >&2; exit 1; }
            read -r run_id sha <<<"$run"
            [ "$sha" = "$(git rev-parse --short=7 HEAD)" ] \
                || echo "warning: flashing the latest green build $sha, local HEAD is $(git rev-parse --short=7 HEAD)" >&2

            dir=$(mktemp -d)
            trap 'rm -rf "$dir"' EXIT
            gh run download -R "$repo" "$run_id" -n firmware -D "$dir"
            uf2=$(find "$dir" -name "$pattern" | head -1)
            [ -n "$uf2" ] || { echo "no $pattern in run $run_id" >&2; exit 1; }
            echo "firmware: $(basename "$uf2") (run $run_id, $sha)"
            ;;
        *) echo "unknown source: {{source}} (local, ci)" >&2; exit 1 ;;
    esac

    if [ ! -d "{{volume}}" ]; then
        ports=($(ioreg -r -l -n "{{product}}" | awk -F'"' '/"IOCalloutDevice"/ {print $4}'))
        if [ "${#ports[@]}" -eq 0 ]; then
            echo "no {{volume}} and no \"{{product}}\" serial port: plug the half in, or press &bootloader" >&2
            exit 1
        fi
        if [ "${#ports[@]}" -ne 1 ]; then
            echo "both halves are plugged in, leave only the one to flash: ${ports[*]}" >&2
            exit 1
        fi
        echo "rebooting ${ports[0]} into the bootloader"
        stty -f "${ports[0]}" 9600 || true
        stty -f "${ports[0]}" 1200 || true
        for _ in $(seq 30); do
            [ -d "{{volume}}" ] && break
            sleep 0.5
        done
        [ -d "{{volume}}" ] || { echo "{{volume}} did not appear" >&2; exit 1; }
    fi

    cp "$uf2" "{{volume}}/" 2>/dev/null || true
    for _ in $(seq 30); do
        [ -d "{{volume}}" ] || { echo "flashed {{side}}"; exit 0; }
        sleep 0.5
    done
    echo "{{volume}} is still mounted, the copy may have failed" >&2
    exit 1

# Bump west dependencies to their branch heads and refresh zephyrDepsHash
update:
    nix run .#update
