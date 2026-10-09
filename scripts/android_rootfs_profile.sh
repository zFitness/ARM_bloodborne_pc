#!/usr/bin/env bash
# Android rootfs/proot performance profile helpers. Sourced by run.sh and the
# packaged /opt/bbport/bin/bbport wrapper; keep this file dependency-light.

bb_android_profile_enabled() {
    [[ ${BB_ANDROID_ROOTFS_PROFILE:-0} == 1 ]]
}

bb_android_set_default() {
    local name=$1 value=$2
    if [[ -z ${!name+x} ]]; then
        printf -v "$name" '%s' "$value"
        export "$name"
        BB_ANDROID_DEFAULT_SUMMARY+="$name=default($value) "
    else
        BB_ANDROID_DEFAULT_SUMMARY+="$name=user(${!name}) "
    fi
}

bb_android_cpu_list_to_set() {
    local list=$1 part start end cpu
    BB_ANDROID_CPU_SET=()
    IFS=',' read -r -a parts <<< "$list"
    for part in "${parts[@]}"; do
        [[ -n $part ]] || continue
        if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}
            (( start <= end )) || continue
            for (( cpu=start; cpu<=end; ++cpu )); do BB_ANDROID_CPU_SET+=("$cpu"); done
        elif [[ $part =~ ^[0-9]+$ ]]; then
            BB_ANDROID_CPU_SET+=("$part")
        fi
    done
}

bb_android_join_cpu_set() {
    local out= cpu
    for cpu in "${BB_ANDROID_CPU_SET[@]:-}"; do
        out+="${out:+,}$cpu"
    done
    printf '%s' "$out"
}

bb_android_detect_big_cores() {
    local best=-1 cpu cap freq path
    BB_ANDROID_CPU_SET=()
    if [[ -n ${BB_BIG_CORES:-} ]]; then
        bb_android_cpu_list_to_set "$BB_BIG_CORES"
        bb_android_join_cpu_set
        return
    fi
    for path in /sys/devices/system/cpu/cpu[0-9]*/cpu_capacity; do
        [[ -r $path ]] || continue
        cpu=${path%/cpu_capacity}
        cpu=${cpu##*cpu}
        read -r cap < "$path" || continue
        [[ $cap =~ ^[0-9]+$ ]] || continue
        if (( cap > best )); then
            best=$cap
            BB_ANDROID_CPU_SET=("$cpu")
        elif (( cap == best )); then
            BB_ANDROID_CPU_SET+=("$cpu")
        fi
    done
    if (( best < 0 )); then
        for path in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/cpuinfo_max_freq; do
            [[ -r $path ]] || continue
            cpu=${path%/cpufreq/cpuinfo_max_freq}
            cpu=${cpu##*cpu}
            read -r freq < "$path" || continue
            [[ $freq =~ ^[0-9]+$ ]] || continue
            if (( freq > best )); then
                best=$freq
                BB_ANDROID_CPU_SET=("$cpu")
            elif (( freq == best )); then
                BB_ANDROID_CPU_SET+=("$cpu")
            fi
        done
    fi
    bb_android_join_cpu_set
}

bb_android_apply_process_affinity() {
    bb_android_profile_enabled || return 0
    [[ ${BB_ANDROID_AFFINITY_APPLIED:-0} == 1 ]] && return 0
    local cpus=${BB_HOST_AFFINITY_CPUS:-}
    if [[ -z $cpus ]]; then
        cpus=$(bb_android_detect_big_cores)
        [[ -n $cpus ]] && export BB_HOST_AFFINITY_CPUS=$cpus
    else
        bb_android_cpu_list_to_set "$cpus"
        cpus=$(bb_android_join_cpu_set)
        export BB_HOST_AFFINITY_CPUS=$cpus
    fi
    [[ -n $cpus ]] || { echo "Android rootfs profile: CPU mask unavailable" >&2; return 0; }
    export BB_GUEST_AFFINITY_MAP=${BB_GUEST_AFFINITY_MAP:-1}
    export BB_ANDROID_AFFINITY_APPLIED=1
    echo "Android rootfs profile: host CPU affinity cpus=$cpus" >&2
    if command -v taskset >/dev/null 2>&1; then
        taskset -pc "$cpus" "$$" >/dev/null 2>&1 ||
            echo "Android rootfs profile: warning: taskset could not apply cpus=$cpus" >&2
    fi
}

# Rootfs system library directories. The wrapper's @LD_LIBRARY_PATH@ covers the packaged
# closure only, and that closure's glibc does not search /usr/lib. An imported Linux/rootfs
# Vulkan driver (Mesa Turnip needs libzstd, libxcb-*, libwayland-client, libxshmfence,
# libdrm, ...) and the prebuilt bb-probe (libffi) resolve those from the rootfs's own
# library directories, so they must be on the library path. Without them the Vulkan loader
# silently drops the imported ICD ("Failed loading library associated with ICD JSON ...:
# libzstd.so.1: cannot open shared object file") and window creation then fails with
# "Installed Vulkan doesn't implement the VK_KHR_surface extension" - the import looks
# ineffective even though the driver is selected and its ICD JSON is correct.
BB_ANDROID_SYSTEM_LIBRARY_DIRS=${BB_ANDROID_SYSTEM_LIBRARY_DIRS:-/usr/local/lib:/usr/lib:/lib:/usr/lib64}
export BB_ANDROID_SYSTEM_LIBRARY_DIRS

bb_android_apply_library_path() {
    bb_android_profile_enabled || return 0
    [[ ${BB_ANDROID_LIBRARY_PATH_APPLIED:-0} == 1 ]] && return 0
    local dirs=${BB_ANDROID_SYSTEM_LIBRARY_DIRS:-} dir
    [[ -n $dirs ]] || return 0
    for dir in ${dirs//:/ }; do
        [[ -d $dir ]] || continue
        # Append, never prepend: the packaged closure (and the imported driver's own
        # directories) keep priority; these are fallbacks for the rootfs's system libs.
        case ":${LD_LIBRARY_PATH:-}:" in
            *":$dir:"*) continue ;;
        esac
        export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}${LD_LIBRARY_PATH:+:}$dir"
    done
    export BB_ANDROID_LIBRARY_PATH_APPLIED=1
}

# Apply this only right before the game/loader starts, never for the whole wrapper: the
# packaged tooling runs on the closure's glibc, and the rootfs's older system libs (its
# /usr/lib/libm.so.6 has no GLIBC_2.44) would break it (bbport-driver then dies with
# "ImportError: /usr/lib/libm.so.6: version `GLIBC_2.44' not found").
bb_android_apply_defaults() {
    bb_android_profile_enabled || return 0
    [[ ${BB_ANDROID_DEFAULTS_APPLIED:-0} == 1 ]] && return 0
    BB_ANDROID_DEFAULT_SUMMARY="Android rootfs profile: defaults "
    bb_android_set_default BB_PREP_WORKERS 2
    bb_android_set_default BB_COPY_THREADS 1
    bb_android_set_default BB_VK_RECORD_THREADS 1
    bb_android_set_default BB_PIPE_SPIN_US 20
    bb_android_set_default BB_GPU_SPIN_US 0
    bb_android_set_default BB_FRAMES_AHEAD 1
    bb_android_set_default BB_FRAME_STATS 1
    bb_android_set_default BB_PC_MODEL_PROBE_ANY_GPU 1
    export BB_ANDROID_DEFAULTS_APPLIED=1
    echo "$BB_ANDROID_DEFAULT_SUMMARY" >&2
    unset BB_ANDROID_DEFAULT_SUMMARY
}

bb_android_path_warn() {
    local label=$1 path=${2:-}
    [[ -n $path ]] || return 0
    case $path in
        /sdcard|/sdcard/*|/storage/emulated/*|/mnt/sdcard|/mnt/sdcard/*)
            echo "Android rootfs profile: warning: $label is on Android shared storage ($path); this may cause loading or shader-cache stutter" >&2
            ;;
    esac
    if [[ -e $path ]]; then
        case $(stat -f -c %T "$path" 2>/dev/null || true) in
            fuseblk|fuse|sdcardfs)
                echo "Android rootfs profile: warning: $label is on a FUSE-like filesystem ($path)" >&2
                ;;
        esac
    fi
}

bb_android_writable_warn() {
    local label=$1 path=$2
    if [[ ! -d $path ]]; then
        mkdir -p "$path" 2>/dev/null || {
            echo "Android rootfs profile: warning: cannot create $label directory: $path" >&2
            return 0
        }
    fi
    [[ -w $path ]] || echo "Android rootfs profile: warning: $label is not writable: $path" >&2
}

bb_android_storage_diagnostics() {
    bb_android_profile_enabled || return 0
    local game=${1:-} data=${2:-} user=${3:-} driver_store=${4:-}
    [[ -n $game ]] && bb_android_path_warn BB_GAME_DIR "$game"
    [[ -n $data ]] && bb_android_path_warn BB_DATA_DIR "$data"
    [[ -n $user ]] && bb_android_path_warn shader-cache "$user/cache"
    [[ -n $driver_store ]] && bb_android_path_warn driver-store "$driver_store"
    [[ -n $data ]] && bb_android_writable_warn BB_DATA_DIR "$data"
    [[ -n $user ]] && bb_android_writable_warn shader-cache "$user/cache"
    [[ -n $driver_store ]] && bb_android_writable_warn driver-store "$driver_store"
    echo "Android rootfs profile: storage game=${game:-unset} data=${data:-unset} user=${user:-unset} driver_store=${driver_store:-unset}" >&2
}

bb_android_runtime_summary() {
    bb_android_profile_enabled || return 0
    echo "Android rootfs profile: summary BB_HOST_AFFINITY_CPUS=${BB_HOST_AFFINITY_CPUS:-unset} BB_GUEST_IN_PLACE=${BB_GUEST_IN_PLACE:-unset} BB_PC_MODEL=${BB_PC_MODEL:-unset} BB_FRAME_STATS=${BB_FRAME_STATS:-unset}" >&2
}
