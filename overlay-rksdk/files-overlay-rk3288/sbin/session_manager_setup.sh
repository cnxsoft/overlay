#!/bin/sh

# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Set up to start the X server ASAP, then let the startup run in the
# background while we set up other stuff.
XUSER=xorg
XTTY=1
XAUTH_FILE="/var/run/chromelogin.auth"
xstart.sh ${XUSER} ${XTTY} ${XAUTH_FILE} &

USE_FLAGS="$(cat /etc/session_manager_use_flags.txt)"

# Returns success if the USE flag passed as its sole parameter was defined.
# New flags must be first be added to the ebuild file.
use_flag_is_set() {
  local flag i
  flag="$1"
  for i in $USE_FLAGS; do
    if [ $i = "${flag}" ]; then
      return 0
    fi
  done
  return 1
}

# Returns success if we were built for the board passed as the sole parameter.
# Not all boards are handled; see the ebuild file.
is_board() {
  use_flag_is_set "board_use_$1"
}

# --vmodule=PATTERN1=LEVEL1,PATTERN2=LEVEL2 flag passed to Chrome to selectively
# enable verbose logging for particular files.
VMODULE_FLAG=

# Appends a pattern to VMODULE_FLAG.
add_vmodule_pattern() {
  if [ -z "$VMODULE_FLAG" ]; then
    VMODULE_FLAG="--vmodule=$1"
  else
    VMODULE_FLAG="$VMODULE_FLAG,$1"
  fi
}

# Takes a wallpaper name and size and returns the corresponding filename.
get_wallpaper_filename() {
  local NAME=$1
  local SIZE=$2
  echo "/usr/share/chromeos-assets/wallpaper/${NAME}_${SIZE}.jpg"
}

# Takes a wallpaper name ("default" or "guest"), size ("large" or "small"),
# and filename and adds the corresponding flag to ASH_FLAGS.
add_wallpaper_flag() {
  local NAME=$1
  local SIZE=$2
  local FILE=$3
  ASH_FLAGS="$ASH_FLAGS --ash-${NAME}-wallpaper-${SIZE}=${FILE}"
}

export USER=chronos
export DATA_DIR=/home/${USER}
export LOGIN_PROFILE_DIR=${DATA_DIR}/Default
export LOGNAME=${USER}
export SHELL=/bin/sh
# TODO(keescook): remove Chrome's use of $HOME.
export HOME=${DATA_DIR}/user
export DISPLAY=:0.0
export XAUTHORITY=${DATA_DIR}/.Xauthority

# Provide /etc/lsb-release contents and timestamp so that they are available
# to Chrome immediately without requiring a blocking file read.
export LSB_RELEASE="$(cat /etc/lsb-release)"
export LSB_RELEASE_TIME="$(stat -c '%Z' /etc/lsb-release)"

# If used with Address Sanitizer, set the following flags to alter memory
# allocations by glibc. Hopefully later, when ASAN matures, we will not need
# any changes for it to run.
ASAN_FLAGS=
if use_flag_is_set asan; then
  # Make glib use system malloc.
  export G_SLICE=always-malloc

  # Make nss skip dlclosing dynamically loaded modules,
  # which would result in "obj:*" in backtraces.
  export NSS_DISABLE_ARENA_FREE_LIST=1

  # Make nss use system malloc.
  export NSS_DISABLE_UNLOAD=1

  # Make ASAN output to the file because
  # Chrome stderr is /dev/null now (crbug.com/156308).
  export ASAN_OPTIONS="log_path=/var/log/chrome/asan_log"

  # Disable sandboxing as it causes crashes in ASAN. crosbug.com/127536.
  ASAN_FLAGS="--no-sandbox"
fi

# If used with Deep Memory Profiler, turn on the heap profiler.
DMPROF_FLAGS=
if use_flag_is_set deep_memory_profiler; then
  if [ -f /var/tmp/deep_memory_profiler_time_interval.txt ] ; then
    read dmprof_time_interval < /var/tmp/deep_memory_profiler_time_interval.txt
  fi
  if [ -f /var/tmp/deep_memory_profiler_prefix.txt ] ; then
    read dmprof_prefix < /var/tmp/deep_memory_profiler_prefix.txt

    # Dump heap profiles to /tmp/dmprof.*.
    export HEAPPROFILE=${dmprof_prefix}

    # Turn on profiling mmap.
    export HEAP_PROFILE_MMAP=1

    # Turn on Deep Memory Profiler.
    export DEEP_HEAP_PROFILE=1

    # Dump every ${dmprof_time_interval} seconds.
    export HEAP_PROFILE_TIME_INTERVAL=${dmprof_time_interval}

    DMPROF_FLAGS="--no-sandbox"
  fi
fi

# By default, libdbus treats all warnings as fatal errors. That's too strict.
export DBUS_FATAL_WARNINGS=0

# Tell Chrome where to write logging messages.
# $CHROME_LOG_DIR and $CHROME_LOG_PREFIX are defined in ui.conf,
# and the directory is created there as well.
export CHROME_LOG_FILE="${CHROME_LOG_DIR}/${CHROME_LOG_PREFIX}"

# Log directory for this session.  Note that ${DATA_DIR}/user might not be
# mounted until later (when the cryptohome is mounted), so we don't
# mkdir CHROMEOS_SESSION_LOG_DIR immediately.
export CHROMEOS_SESSION_LOG_DIR="${DATA_DIR}/user/log"

# Forces Chrome mini dumps that are sent to the crash server to also be written
# locally.  Chrome by default will create these mini dump files in
# ~/.config/google-chrome/Crash Reports/
if [ -f /mnt/stateful_partition/etc/enable_chromium_minidumps ] ; then
  export CHROME_HEADLESS=1
  # If possible we would like to have the crash reports located somewhere else
  if [ ! -f ~/.config/google-chrome/Crash\ Reports ] ; then
    mkdir -p /var/minidumps/
    chown chronos /var/minidumps/
    ln -s /var/minidumps/ \
      ~/.config/google-chrome/Crash\ Reports
  fi
fi

mkdir -p ${DATA_DIR} && chown ${USER}:${USER} ${DATA_DIR}
mkdir -p ${DATA_DIR}/user && chown ${USER}:${USER} ${DATA_DIR}/user

# Old builds will have a ${LOGIN_PROFILE_DIR} that's owned by root; newer ones
# won't have this directory at all.
mkdir -p ${LOGIN_PROFILE_DIR}
chown ${USER}:${USER} ${LOGIN_PROFILE_DIR}

CHROME="/opt/google/chrome/chrome"
CONSENT_FILE="$DATA_DIR/Consent To Send Stats"

# xdg-open is used to open downloaded files.
# It runs sensible-browser, which uses $BROWSER.
export BROWSER=${CHROME}

USER_ID=$(id -u ${USER})

# To always force OOBE. This works ok with test images so that they
# always start with OOBE.
if [ -f /root/.test_repeat_oobe ] ; then
  rm -f "${DATA_DIR}/.oobe_completed"
  rm -f "${DATA_DIR}/Local State"
fi

SSLKEYLOGFILE=/var/log/sslkeys.log
if use_flag_is_set dangerous_sslkeylogfile &&
   [ -f "$SSLKEYLOGFILE" ]; then
  # Exporting this environment variable turns on a useful diagnostic
  # feature in Chrome/NSS, which can allow users to decrypt their own
  # SSL traffic later with e.g. Wireshark. We key this off of both a
  # USE flag stored on rootfs (which, essentially, locks this feature
  # off for normal systems), and, the logfile itself (which makes this
  # feature easy to toggle on/off, on systems like mod-for-test
  # images, where the USE flag has been customized to permit its use).
  export SSLKEYLOGFILE
fi

# Enables gathering of chrome dumps.  In stateful partition so testers
# can enable getting core dumps after build time.
if [ -f /mnt/stateful_partition/etc/enable_chromium_coredumps ] ; then
  mkdir -p /var/coredumps/
  # Chrome runs and chronos so we need to change the permissions of this folder
  # so it can write there when it crashes
  chown chronos /var/coredumps/
  ulimit -c unlimited
  echo "/var/coredumps/core.%e.%p" > \
    /proc/sys/kernel/core_pattern
fi

# Remove consent file if it had at one point been created by this script.
if [ -f "$CONSENT_FILE" ]; then
  CONSENT_USER_GROUP=$(stat -c %U:%G "$CONSENT_FILE")
  # normally, the consent file would be owned by "chronos:chronos".
  if [ "$CONSENT_USER_GROUP" = "root:root" ]; then
    TAG="$(basename $0)[$$]"
    logger -t "${TAG}" "Removing consent file owned by root"
    rm -f "$CONSENT_FILE"
  fi
fi

# Allow Chrome to access GPU memory information despite /sys/kernel/debug
# being owned by debugd. This limits the security attack surface versus
# leaving the whole debug directory world-readable. http://crbug.com/175828
DEBUGFS_GPU=/var/run/debugfs_gpu
if [ ! -d $DEBUGFS_GPU ]; then
  mkdir -p $DEBUGFS_GPU
  mount -o bind /sys/kernel/debug/dri/0 $DEBUGFS_GPU
fi

# We need to delete these files as Chrome may have left them around from
# its prior run (if it crashed).
rm -f ${DATA_DIR}/SingletonLock
rm -f ${DATA_DIR}/SingletonSocket

# Set an environment variable to prevent Flash asserts from crashing the plugin
# process.
export DONT_CRASH_ON_ASSERT=1

# Look for pepper plugins and register them
PEPPER_PATH=/opt/google/chrome/pepper
REGISTER_PLUGINS=
COMMA=
FLASH_FLAGS=
PPAPI_FLASH_FLAGS=
for file in $(find $PEPPER_PATH -name '*.info'); do
  FILE_NAME=
  PLUGIN_NAME=
  DESCRIPTION=
  VERSION=
  MIME_TYPES=
  . $file
  [ -z "$FILE_NAME" ] && continue
  PLUGIN_STRING="${FILE_NAME}"
  if [ -n "$PLUGIN_NAME" ]; then
    PLUGIN_STRING="${PLUGIN_STRING}#${PLUGIN_NAME}"
    if [ -n "$DESCRIPTION" ]; then
      PLUGIN_STRING="${PLUGIN_STRING}#${DESCRIPTION}"
      [ -n "$VERSION" ] && PLUGIN_STRING="${PLUGIN_STRING}#${VERSION}"
    fi
  fi
  if [ "$PLUGIN_NAME" = "Shockwave Flash" ]; then
    # Flash is treated specially.
    FLASH_FLAGS="--ppapi-flash-path=${FILE_NAME}"
    FLASH_FLAGS="${FLASH_FLAGS} --ppapi-flash-version=${VERSION}"
    # TODO(ihf): Remove once crbug.com/237380 and crbug.com/276738 are fixed.
    if is_board x86-alex || is_board x86-alex_he || is_board x86-mario ||
        is_board x86-zgb || is_board x86-zgb_he ; then
      PPAPI_FLASH_FLAGS="--ppapi-flash-args=enable_hw_video_decode=0"
    else
      PPAPI_FLASH_FLAGS="--ppapi-flash-args=enable_hw_video_decode=1"
    fi
  else
    PLUGIN_STRING="${PLUGIN_STRING};${MIME_TYPES}"
    REGISTER_PLUGINS="${REGISTER_PLUGINS}${COMMA}${PLUGIN_STRING}"
    COMMA=","
  fi
done
if [ -n "$REGISTER_PLUGINS" ]; then
  REGISTER_PLUGINS="--register-pepper-plugins=$REGISTER_PLUGINS"
fi

# Enable natural scroll by default.
TOUCHPAD_FLAGS=
if use_flag_is_set natural_scroll_default; then
  TOUCHPAD_FLAGS="--enable-natural-scroll-default"
fi

KEYBOARD_FLAGS=
if ! use_flag_is_set legacy_keyboard; then
  KEYBOARD_FLAGS="--has-chromeos-keyboard"
fi

if use_flag_is_set has_diamond_key; then
  KEYBOARD_FLAGS="$KEYBOARD_FLAGS --has-chromeos-diamond-key"
fi

ASH_FLAGS=
if use_flag_is_set legacy_power_button; then
  ASH_FLAGS="$ASH_FLAGS --aura-legacy-power-button"
fi
if use_flag_is_set disable_login_animations; then
  ASH_FLAGS="$ASH_FLAGS --disable-login-animations"
  ASH_FLAGS="$ASH_FLAGS --disable-boot-animation"
  ASH_FLAGS="$ASH_FLAGS --ash-copy-host-background-at-boot"
elif use_flag_is_set fade_boot_splash_screen; then
  ASH_FLAGS="$ASH_FLAGS --ash-animate-from-boot-splash-screen"
fi

if [ -e $(get_wallpaper_filename oem large) ] &&
   [ -e $(get_wallpaper_filename oem small) ]; then
  add_wallpaper_flag default large $(get_wallpaper_filename oem large)
  add_wallpaper_flag default small $(get_wallpaper_filename oem small)
  ASH_FLAGS="$ASH_FLAGS --ash-default-wallpaper-is-oem"
elif [ -e $(get_wallpaper_filename default large) ] &&
     [ -e $(get_wallpaper_filename default small) ]; then
  add_wallpaper_flag default large $(get_wallpaper_filename default large)
  add_wallpaper_flag default small $(get_wallpaper_filename default small)
fi

if [ -e $(get_wallpaper_filename guest large) ] &&
   [ -e $(get_wallpaper_filename guest small) ]; then
  add_wallpaper_flag guest large $(get_wallpaper_filename guest large)
  add_wallpaper_flag guest small $(get_wallpaper_filename guest small)
fi

# Setup GPU & acceleration flags which differ between SoCs that
# use EGL/GLX rendering
if use_flag_is_set egl; then
  ACCELERATED_FLAGS="--use-gl=egl"
fi

  ACCELERATED_FLAGS="--use-gl=egl"
PPAPI_OOP_FLAG=
if use_flag_is_set exynos; then
  PPAPI_OOP_FLAG="--ppapi-out-of-process"
  # On boards with ARM NEON support, force libvpx to use the NEON-optimized
  # code paths. Remove once http://crbug.com/161834 is fixed.
  # This is needed because libvpx cannot check cpuinfo within the sandbox.
  export VPX_SIMD_CAPS=0xf
fi

HIGHDPI_FLAGS=
if use_flag_is_set highdpi; then
  HIGHDPI_FLAGS="$HIGHDPI_FLAGS --enable-webkit-text-subpixel-positioning"
  HIGHDPI_FLAGS="$HIGHDPI_FLAGS --enable-accelerated-overflow-scroll"
  HIGHDPI_FLAGS="$HIGHDPI_FLAGS --default-tile-width=512"
  HIGHDPI_FLAGS="$HIGHDPI_FLAGS --default-tile-height=512"
fi

TOUCHUI_FLAGS=
if is_board link; then
  TOUCHUI_FLAGS="--touch-calibration=0,0,0,50"
fi

# Device Manager Server used to fetch the enterprise policy, if applicable.
DMSERVER="https://m.google.com/devicemanagement/data/api"

# For i18n keyboard support (crbug.com/116999)
export LC_ALL=en_US.utf8

# On platforms with rotational disks, Chrome takes longer to shut down.
# As such, we need to change our baseline assumption about what "taking too long
# to shutdown" means and wait for longer before killing Chrome and triggering
# a report.
KILL_TIMEOUT_FLAG=
if use_flag_is_set has_hdd; then
  KILL_TIMEOUT_FLAG="--kill-timeout=12"
fi

# The session_manager supports pinging the browser periodically to
# check that it is still alive.  On developer systems, this would be a
# problem, as debugging the browser would cause it to be aborted.
# Override via a flag-file is allowed to enable integration testing.
HANG_DETECTION_FLAG_FILE=/var/run/session_manager/enable_hang_detection
HANG_DETECTION_FLAG=
if ! is_developer_end_user; then
  HANG_DETECTION_FLAG="--enable-hang-detection"
elif [ -f ${HANG_DETECTION_FLAG_FILE} ]; then
  HANG_DETECTION_FLAG="--enable-hang-detection=5"  # And do it FASTER!
fi

GPU_FLAGS=
  GPU_FLAGS="$GPU_FLAGS --gpu-sandbox-allow-sysv-shm"
if use_flag_is_set gpu_sandbox_allow_sysv_shm; then
  GPU_FLAGS="$GPU_FLAGS --gpu-sandbox-allow-sysv-shm"
fi

VIDEO_FLAGS=
if is_board peach_pit; then
  VIDEO_FLAGS="--enable-webrtc-hw-vp8-encoding"
fi

# There has been a steady supply of bug reports about screen locking. These
# messages are useful for determining what happened within feedback reports.
add_vmodule_pattern "screen_locker=1"
add_vmodule_pattern "webui_screen_locker=1"

# TODO(ygorshenin): Remove this once we will have logs from places
# where shill was tested (crosbug.com/36622).
add_vmodule_pattern "network_portal_detector_impl=1"

# Turn on logging about external displays being connected and disconnected.
# Different behavior is seen from different displays and these messages are used
# to determine what happened within feedback reports.
add_vmodule_pattern "*output_configurator*=1"
add_vmodule_pattern "*ash/display*=1"

# Turn on plugin loading failure logging for crbug.com/314301.
add_vmodule_pattern "*zygote*=1"
add_vmodule_pattern "*plugin*=2"

# The subshell that started the X server will terminate once X is
# ready.  Wait here for that event before continuing.
#
# RED ALERT!  The code from the 'wait' to the end of the script is
# part of the boot time critical path.  Every millisecond spent after
# the wait is a millisecond longer till the login screen.
#
# KEEP THIS CODE PATH CLEAN!  The code must be obviously fast by
# inspection; nothing should go after the wait that isn't required
# for correctness.

wait

# Create the XAUTHORITY file so ${USER} can access the X server.
# This must happen after xstart.sh has finished (and created ${XAUTH_FILE}),
# hence after the wait.
cp -f ${XAUTH_FILE} ${XAUTHORITY} && chown ${USER}:${USER} ${XAUTHORITY}

initctl emit x-started
bootstat x-started

# This is a bad place to add your code.  See "RED ALERT", above.
# Regrettably, this comment is not redundant.  :-(

#
# Reset PATH to exclude directories unneeded by session_manager.
# Save that until here, because many of the commands above depend
# on the default PATH handed to us by init.
#
export PATH=/bin:/usr/bin:/usr/bin/X11

exec /sbin/session_manager --uid=${USER_ID} ${KILL_TIMEOUT_FLAG} \
    ${HANG_DETECTION_FLAG} -- \
    $CHROME --allow-webui-compositing \
            --device-management-url="$DMSERVER" \
            --enable-chrome-audio-switching \
            --enable-fixed-position-compositing \
            --enable-logging \
            --enable-partial-swap \
            --enable-impl-side-painting \
            --max-tiles-for-interest-area=512 \
            --enterprise-enrollment-initial-modulus=8 \
            --enterprise-enrollment-modulus-limit=12 \
            --log-level=1 \
            --login-manager \
            --login-profile=user \
            --max-unused-resource-memory-usage-percentage=5 \
            --no-protector \
	    --no-sandbox \
	    --ui-enable-per-tile-painting \
            --ui-prioritize-in-gpu-process \
            --ui-max-frames-pending=1 \
            --use-cras \
            --user-data-dir="$DATA_DIR" \
            "$REGISTER_PLUGINS" \
            ${ACCELERATED_FLAGS} \
            ${ASH_FLAGS} \
            ${FLASH_FLAGS} \
            ${HIGHDPI_FLAGS} \
            ${TOUCHPAD_FLAGS} \
            ${KEYBOARD_FLAGS} \
            ${TOUCHUI_FLAGS} \
            ${ASAN_FLAGS} \
            ${DMPROF_FLAGS} \
            ${PPAPI_FLASH_FLAGS} \
            ${PPAPI_OOP_FLAG} \
            ${VMODULE_FLAG} \
            ${GPU_FLAGS} \
            ${VIDEO_FLAGS}
