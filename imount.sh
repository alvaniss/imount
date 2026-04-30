#!/bin/bash

# Copyright (C) 2026 alvaniss
#
# This file is part of imount.
#
# This program is free software licensed under the GNU General Public License v3.0.
# See the LICENSE file for details.

set -u

trap cleanup INT TERM EXIT

CONFIG_DIR="$HOME/.config/imount"
CONFIG_FILE="$CONFIG_DIR/default-app"
MONITOR_PID=""

load_default_app() {
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE"
    else
        echo ""
    fi
}

save_default_app() {
    mkdir -p "$CONFIG_DIR"
    echo "$1" > "$CONFIG_FILE"
}

cleanup() {
    kill "$MONITOR_PID" 2>/dev/null
    pkill -P $$ 2>/dev/null

    local mountpoint="$HOME/imount"

    if mountpoint -q "$mountpoint" 2>/dev/null; then
        fusermount -u -z "$mountpoint" 2>/dev/null
    fi

    umount "$mountpoint" 2>/dev/null; [ -d "$mountpoint" ] && rmdir "$mountpoint" 2>/dev/null

    tput cnorm # restore thingy
    stty sane
    clear
    exit 0
}

monitor_device() {
    local was_connected=0
    local output

    while true; do
        output="$(idevicepair validate 2>&1)"
        local status=$?

        if [ $status -eq 0 ]; then
            was_connected=1

        elif [[ "$was_connected" -eq 1 && "$output" == *"No device found"* ]]; then
            kill -TERM $$ 2>/dev/null
            exit
            clear
        fi

        sleep 1
    done
}

listen_for_q() {
    while true; do
        local key
        read -rsn1 key
        if [[ "$key" == "q" ]]; then
            cleanup
        fi
    done
}

check_for_q() {
    local key
    read -rsn1 -t 0.01 key
    [[ "$key" == "q" ]] && cleanup
}

device_info() {
    echo Device Class: "$device_class"
    echo Device Name:"$device_name"
    echo Battery: "$device_battery"%
    echo Storage Free: "$device_disk"GB
    echo

}

choose_app() {
    local selected=0
    local key
    local default_app
    default_app="$(load_default_app)"

    tput civis # hide thingy

    # select the default app if set
    if [ -n "$default_app" ]; then
        for i in "${!options[@]}"; do
            if [ "${options[$i]}" = "$default_app" ]; then
                selected=$i
                break
            fi
        done
    fi

    while true; do
        clear

        if [ -n "${last_msg:-}" ]; then
            if [ "$last_msg" != "$msg" ]; then
                echo -e "$last_msg"
                echo
            fi
        fi

        device_info
        echo "Available apps (↑ ↓ to move, Enter to select, d to set/remove default app, q to quit):"
        echo

        for i in "${!options[@]}"; do
            local label="${options[$i]}"
            [ "${options[$i]}" = "$default_app" ] && label="[default] $label"
            if [ "$i" -eq "$selected" ]; then
                printf " > %s\n" "$label"
            else
                printf "   %s\n" "$label"
            fi
        done

        read -rsn1 key

        case "$key" in
            q)
                tput cnorm # restore thingy
                cleanup
                ;;
            d)
                if [ "${options[$selected]}" = "$default_app" ]; then
                    rm -f "$CONFIG_FILE"
                    default_app=""
                else
                    save_default_app "${options[$selected]}"
                    default_app="${options[$selected]}"
                fi
                ;;
            "")
                tput cnorm # restore thingy
                choice="${options[$selected]}"
                return
                ;;
            $'\x1b')
                read -rsn2 key
                case "$key" in
                    "[A")   # up arrow
                        (( selected-- ))
                        [ "$selected" -lt 0 ] && selected=$(( ${#options[@]} - 1 ))
                        ;;
                    "[B")   # down arrow
                        (( selected++ ))
                        [ "$selected" -ge "${#options[@]}" ] && selected=0
                        ;;
                esac
                ;;
        esac
    done
}

wait_for_done() {
    local key
    echo
    echo "Press [Enter] to unmount, [d] for apps list, or [q] to quit."

    while true; do
        tput civis
        read -rsn1 key
        case "$key" in
            q)  cleanup;;
            d)  return 2 ;;  # go to choose_app
            "")  return 2 ;;  # stupid but kinda how it should be
        esac
    done
}

listen_for_q &
monitor_device &
MONITOR_PID=$!

# main loop
skip_chooser_next=0

while true; do

    pair_status=""
    mountpoint="$HOME/imount"
    default_app="$(load_default_app)"
    clear
    tput civis

    while [ "$pair_status" != "0" ]; do
        pair_output="$(idevicepair validate 2>&1)"
        pair_status=$?

        if [ "$pair_status" != "0" ]; then
            case "$pair_output" in
                *"No device found"*)
                    msg="Please connect an iOS or iPadOS device..."
                    ;;
                *"Please enter the passcode on the device and retry"*)
                    msg="Please unlock the device..."
                    ;;
                *"Please accept the trust dialog on the screen of device"*)
                    msg="Please accept the trust prompt on the device..."
                    ;;
                *"the user denied the trust dialog"*)
                    msg="Trust prompt was denied — please disconnect and reconnect the device..."
                    ;;
                *"is not paired with this host"*)
                    msg="${last_msg:-Pairing device...}"
                    ;;
                *)
                    msg="Something went wrong pairing the device.\nError:\n$pair_output"
                    ;;
            esac

            if [ "${last_msg:-}" != "$msg" ]; then
                last_msg="$msg"
                echo -e "$msg"
                echo "Press [q] to quit."
            fi

            for _ in {1..25}; do
                check_for_q
                sleep 0.01
            done
        fi
    done

    tput cnorm

    # build app list
    unset apps; declare -A apps
    while IFS=: read -r name identifier; do
        apps["$name"]="$identifier"
    done <<< "$(
        ifuse --list-apps \
        | grep -v CFBundleIdentifier \
        | awk -F '","' '{printf "%s:%s\n", substr($3, 1, length($3)-1), substr($1, 2)}' \
        | sort
    )"

    unset options; declare -a options
    options=("Filesystem (Photos and Media)")
    while IFS='' read -r app; do
        options+=("$app")
    done <<< "$(for app in "${!apps[@]}"; do echo "$app"; done | sort)"

    # auto mount if default exists
    if [ "$skip_chooser_next" -eq 0 ] && [ -n "$default_app" ]; then
        valid=0
        for opt in "${options[@]}"; do
            [ "$opt" = "$default_app" ] && valid=1 && break
        done
        [ "$valid" -eq 1 ] && choice="$default_app" && skip_chooser=1 || skip_chooser=0
    else
        skip_chooser=0
        skip_chooser_next=0
    fi

    device_class=$(ideviceinfo | grep "DeviceClass" | cut -d' ' -f2)
    device_name=$(ideviceinfo | grep "DeviceName" | cut -d':' -f2)
    device_battery=$(ideviceinfo -q com.apple.mobile.battery | grep "BatteryCurrentCapacity" | cut -d' ' -f2)
    device_disk=$(ideviceinfo -q com.apple.disk_usage | grep "AmountDataAvailable" | cut -d' ' -f2 | awk '{printf "%.2f", $1/1073741824}')

    if [ "$skip_chooser" -eq 0 ]; then
        choose_app

        if [ "$choice" != "Filesystem (Photos and Media)" ] && [[ ! -v apps["$choice"] ]]; then
            echo "No option selected, exiting..."
            exit 0
        fi
    fi

    # prep mountpoint
    mkdir -p "$mountpoint" &>/dev/null
    ifuse_output="$(fusermount -u -z "$mountpoint" 2>&1)"
    ifuse_status=$?

    if [ "$ifuse_status" != "0" ] && [[ "$ifuse_output" != *"not found"* ]]; then
        echo -e "Something went wrong while preparing $mountpoint.\nError:\n$ifuse_output"
        continue
    fi

    # mount
    clear

    if [ "$choice" = "Filesystem (Photos and Media)" ]; then
        ifuse_output="$(ifuse "$mountpoint" 2>&1)"
        ifuse_status=$?
        if [ "$ifuse_status" = "0" ]; then
            msg="Successfully mounted device filesystem on $mountpoint!"
        else
            msg="Something went wrong while mounting device filesystem on $mountpoint."
        fi
    else
        ifuse_output="$(ifuse --documents "${apps["$choice"]}" "$mountpoint" 2>&1)"
        ifuse_status=$?
        if [ "$ifuse_status" = "0" ]; then
            msg="Successfully mounted $choice on $mountpoint!"
        else
            msg="Something went wrong while mounting $choice on $mountpoint."
        fi
    fi

    xdg-open "$mountpoint" &>/dev/null &
    disown

    if [ "$ifuse_status" != "0" ]; then
        echo -e "$msg\nError:\n$ifuse_output"
        continue
    fi

    device_info
    echo -e "$msg"

    wait_for_done
        wait_result=$?

        if [ "$wait_result" -eq 2 ]; then
            skip_chooser_next=1
        else
            skip_chooser_next=0
        fi


    # unmount
    ifuse_output="$(fusermount -u -z "$mountpoint" 2>&1)"
    ifuse_status=$?

    if [ "$ifuse_status" = "0" ]; then
        rmdir "$mountpoint"
        last_msg="Successfully unmounted and deleted folder $mountpoint!"
    else
        last_msg="Something went wrong while unmounting $mountpoint.\nError:\n$ifuse_output"
        continue
    fi

done
