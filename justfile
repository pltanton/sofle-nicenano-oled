volume := "/Volumes/NICENANO"
# CONFIG_USB_DEVICE_PRODUCT in snippets/bootloader-on-1200-baud
product := "Sofle bootloader"

# Flash one half from the latest successful CI build of the current branch: just flash left|right|settings_reset
flash side:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{side}}" in
        left|right) pattern="sofle_{{side}} *.uf2" ;;
        settings_reset) pattern="settings_reset-*.uf2" ;;
        *) echo "unknown side: {{side}} (left, right, settings_reset)" >&2; exit 1 ;;
    esac

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
