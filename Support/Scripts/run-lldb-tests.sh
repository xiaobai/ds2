#!/usr/bin/env bash
##
## Copyright (c) 2014-present, Facebook, Inc.
## All rights reserved.
##
## This source code is licensed under the University of Illinois/NCSA Open
## Source License found in the LICENSE file in the root directory of this
## source tree. An additional grant of patent rights can be found in the
## PATENTS file in the same directory.
##

# This script runs the full lldb test suite found in the LLDB repository
# against ds2. It requires a few hacks in the testing infra to disable
# broken unit tests.

cherry_pick_patches() {
  cd "$1"

  # Disabled and enabled tests
  local testingPath="$top/Support/Testing"

  if [[ "$platform_name" = "android" ]]; then
    # This patch is purely to improve performance on CircleCI, won't ever be upstreamed.
    patch -d "$lldb_path" -p1 < "$testingPath/Patches/android-search-paths.patch"
    patch -d "$lldb_path" -p1 < "$testingPath/Patches/getplatform-workaround.patch"
  fi

  cd "$OLDPWD"
}

get_android_compiler() {
  case "$1" in
    *-ARM) cc_name="arm-linux-androideabi-gcc";;
    *-X86) cc_name="i686-linux-android-gcc";;
    *) die "Running LLDB tests on $1 is not yet supported"
  esac
  echo "$(find /tmp/android-ndk -name $cc_name)"
}

REPO_BASE="https://github.com/llvm-mirror"
UPSTREAM_BRANCH="release_60"
TARGET="${TARGET-${CIRCLE_JOB}}"

top="$(git rev-parse --show-toplevel)"
build_dir="$PWD"

source "$top/Support/Scripts/common.sh"
host_platform_name=$(get_host_platform_name)

[ "${host_platform_name}" == "linux" ] || die "The lldb test suite requires a Linux host environment."
[ -x "$build_dir/ds2" ]   || die "Unable to find a ds2 binary in the current directory."

opt_fast=false
opt_no_ds2_blacklists=false
opt_no_upstream_blacklists=false
opt_log=false
opt_strace=false
opt_use_lldb_server=false

for o in "$@"; do
  case "$o" in
    --fast) opt_fast=true;;
    --no-ds2-blacklists) opt_no_ds2_blacklists=true;;
    --no-upstream-blacklists) opt_no_upstream_blacklists=true;;
    --log) opt_log=true;;
    --strace) opt_strace=true;;
    --use-lldb-server) opt_use_lldb_server=true;;
    *) die "Unknown option \`$o'.";;
  esac
done

if $opt_use_lldb_server && $opt_log; then
  die "Logging with lldb-server is unsupported"
fi

# We modify $PATH here so that the lldb testing framework can call adb
export PATH="/tmp/android-sdk-${host_platform_name}/platform-tools:${PATH}"

if [[ "${TARGET-}" = Android-* ]]; then
  adb wait-for-device
  platform_name="android"
else
  platform_name="linux"
fi

if [ "$(linux_distribution)" == "centos" ]; then
  llvm_path="$build_dir/llvm"
  llvm_build="$llvm_path/build"
  lldb_path="$llvm_path/tools/lldb"
  lldb_exe="$llvm_build/bin/lldb"
  cc_exe="$(which gcc)"

  if ! $opt_fast; then
    git_clone "$REPO_BASE/llvm.git"  "$llvm_path"             "$UPSTREAM_BRANCH"
    git_clone "$REPO_BASE/lldb.git"  "$llvm_path/tools/lldb"  "$UPSTREAM_BRANCH"
    git_clone "$REPO_BASE/clang.git" "$llvm_path/tools/clang" "$UPSTREAM_BRANCH"

    cherry_pick_patches "$llvm_path/tools/lldb"

    if [ -z "${LLDB_EXE-}" ] ; then
      mkdir -p "$llvm_build"
      cd "$llvm_build"
      cmake -G Ninja ..
      ninja lldb
    fi
  fi
elif [ "$(linux_distribution)" == "ubuntu" ]; then
  lldb_path="$build_dir/lldb"
  lldb_exe="$(which lldb-6.0)"

  case "${TARGET}" in
    Android-*)     cc_exe="$(get_android_compiler ${TARGET})";;
    *)             cc_exe="$(which gcc)";;
  esac

  python_base="$build_dir/lib"
  export LD_LIBRARY_PATH=$python_base
  export PYTHONPATH="$python_base/python2.7/site-packages"

  if ! $opt_fast; then
    git_clone "$REPO_BASE/lldb.git" "$lldb_path" "$UPSTREAM_BRANCH"

    cherry_pick_patches "$lldb_path"

    # Sync lldb libs to local build dir
    rsync -a /usr/lib/x86_64-linux-gnu/       "$python_base"
    rsync -a /usr/lib/llvm-6.0/lib/python2.7/ "$python_base/python2.7"
    rsync -a "$python_base/liblldb-6.0.so"    "$python_base/liblldb.so"

    # Fix broken python lldb symlinks
    cd "$PYTHONPATH/lldb"
    for path in $( ls *.so* ); do
      new_link="$(readlink "$path" | sed 's,x86_64-linux-gnu/,,g' | sed 's,../../../../../,../../../,g')"
      rm "$path"
      ln -s "$new_link" "$path"
    done
  fi
else
  die "Testing is only supported on CentOS and Ubuntu."
fi

if [ -n "${LLDB_EXE-}" ] ; then
  lldb_exe=${LLDB_EXE}
fi

cd "$lldb_path/test"

blacklist_dir="$top/Support/Testing/Blacklists"
args=(-q --executable "$lldb_exe" -u CXXFLAGS -u CFLAGS -C "$cc_exe" -v)

if ! $opt_no_upstream_blacklists; then
  args+=("--excluded" "$blacklist_dir/upstream/general.blacklist"
         "--excluded" "$blacklist_dir/upstream/non-debugserver-tests.blacklist")
fi

if ! $opt_no_ds2_blacklists; then
  args+=("--excluded" "$blacklist_dir/ds2/general.blacklist")
  if [ "$(linux_distribution)" == "centos" ]; then
    args+=("--excluded" "$blacklist_dir/ds2/centos.blacklist")
  fi
fi

if [ -n "${TARGET-}" ]; then
  if [[ "${TARGET}" == "Linux-X86_64" || "${TARGET}" == "Linux-X86_64-Clang" ]]; then
    args+=("--arch=x86_64")
    if ! $opt_no_ds2_blacklists; then
      args+=("--excluded" "$blacklist_dir/ds2/x86_64.blacklist")
    fi
    if [[ "${PLATFORM-}" = "1" ]]; then
      args+=("--excluded" "$blacklist_dir/ds2/llvm_60.blacklist")
    fi
  elif [[ "${TARGET}" == "Linux-X86" || "${TARGET}" == "Linux-X86-Clang" || "${TARGET}" == "Android-X86" ]]; then
    args+=("--arch=i386")
    if ! $opt_no_upstream_blacklists; then
      args+=("--excluded" "$blacklist_dir/upstream/x86.blacklist")
    fi
    if ! $opt_no_ds2_blacklists; then
      args+=("--excluded" "$blacklist_dir/ds2/x86.blacklist")
    fi
    if [[ "${PLATFORM-}" = "1" ]]; then
      args+=("--excluded" "$blacklist_dir/ds2/llvm_60.blacklist")
      if ! $opt_no_upstream_blacklists; then
        args+=("--excluded" "$blacklist_dir/upstream/x86-platform.blacklist")
      fi
    fi
  elif [[ "${TARGET}" == "Android-ARM" ]]; then
    args+=("--arch=arm")
  fi
else
  # If this is a developer run (not running on Travis with a $TARGET), run all
  # tests by default.
  LLDB_TESTS="${LLDB_TESTS-all}"

  if [[ "$(uname -m)" = "x86_64" ]]; then
    args+=("--arch=x86_64")
  elif [[ "$(uname -m)" =~ "i[3-6]86" ]]; then
    args+=("--arch=i386")
  fi
fi

if $opt_strace; then
  cat >"$build_dir/ds2-strace.sh" <<EEOOFF
#!/usr/bin/env bash
exec strace -o $build_dir/ds2-strace.log $build_dir/ds2 "\$@"
EEOOFF
  chmod +x "$build_dir/ds2-strace.sh"
  server_path="$build_dir/ds2-strace.sh"
elif $opt_use_lldb_server; then
  server_path="$(which lldb-server-6.0)"
else
  server_path="$build_dir/ds2"
fi

if [[ "${PLATFORM-}" = "1" ]]; then
  if [[ "$platform_name" = "linux" ]]; then
    working_dir="$build_dir"
  elif [[ "$platform_name" = "android" ]]; then
    working_dir="/data/local/tmp"
    if ! $opt_no_ds2_blacklists; then
      args+=("--excluded" "$blacklist_dir/ds2/android.blacklist")
    fi
  fi

  server_port="12345"

  args+=("--platform-name=remote-$platform_name" "--platform-url=connect://localhost:$server_port"
         "--platform-working-dir=$working_dir" "--no-multiprocess")
  if ! $opt_no_upstream_blacklists; then
    args+=("--excluded" "$blacklist_dir/upstream/platform.blacklist")
  fi
  if ! $opt_no_ds2_blacklists; then
    args+=("--excluded" "$blacklist_dir/ds2/platform.blacklist")
  fi

  server_args=("p" "--server" "--listen" "127.0.0.1:$server_port")

  if ! $opt_use_lldb_server && $opt_log; then
    server_args+=("--remote-debug" "--log-file=$working_dir/$(basename "$server_path").log")
  fi

  if [[ "$platform_name" = "linux" ]]; then
    "$server_path" "${server_args[@]}" &
    add_exit_handler kill -9 $!
  elif [[ "$platform_name" = "android" ]]; then
    debug_libdir="/tmp/debug-data/"
    mkdir -p "$debug_libdir"
    debug_libs=("/system/bin/linker" "/system/lib/libc.so" "/system/lib/libm.so" "/system/lib/libstdc++.so")
    for lib in "${debug_libs[@]}" ; do
      adb pull "$lib" "$debug_libdir"
    done
    adb push "$server_path" "$working_dir"
    adb shell "$working_dir/ds2" "${server_args[@]}" &
  fi
  sleep 3
else
  if ! $opt_use_lldb_server && $opt_log; then
    export LLDB_DEBUGSERVER_LOG_FILE="$build_dir/ds2.log"
    export LLDB_DEBUGSERVER_EXTRA_ARG_1="--remote-debug"
  fi
  export LLDB_DEBUGSERVER_PATH="$server_path"
fi

export LLDB_TEST_TIMEOUT=8m

if [ "${LLDB_TESTS-all}" != "all" ]; then
  args+=(-p "$LLDB_TESTS")
fi

python2.7 dotest.py "${args[@]}"
