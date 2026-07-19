#!/usr/bin/env bash
# win.sh — daily driver for the Windows test VM (real-Windows leg of local CI).
#
# All commands run over ssh (local UTM network only — nothing leaves the
# machine). Config: ~/.claude/cbm-vm/config (CBM_VM_HOST, CBM_VM_USER),
# key: ~/.claude/cbm-vm/id_ed25519. Provision first: provision-windows.sh.
#
# Usage:
#   win.sh status                  # reachability + repo + build state
#   win.sh update                  # fetch+reset repo to pushed branch, rebuild
#   win.sh build                   # incremental native build (binary+runner)
#   win.sh test <suite...>         # run test-runner suites (native ARM64)
#   win.sh guards                  # run the Windows guard scripts (python)
#   win.sh smoke-install           # real managed-install E2E (Phase 8 class)
#   win.sh sh <command...>         # arbitrary command in CLANGARM64 env
#   win.sh push-file <local> <vm>  # scp one file into the VM (WIP iteration)
#   win.sh test-par                # full suite, parallel on all VM cores
#   win.sh ubsan-build|ubsan-test  # UBSan at CI's x86_64 arch (emulated; works)
#   win.sh pageheap on|off         # OS heap verification for native runs
set -euo pipefail

CONFIG="${HOME}/.claude/cbm-vm/config"
KEY="${HOME}/.claude/cbm-vm/id_ed25519"
[ -f "$CONFIG" ] && . "$CONFIG"
HOST="${CBM_VM_HOST:?set CBM_VM_HOST in ~/.claude/cbm-vm/config}"
USER_="${CBM_VM_USER:-test}"
BRANCH="${CBM_VM_BRANCH:-feat/shared-coordination-daemon}"
JOBS='\$(nproc)'

SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o ConnectTimeout=10 -o BatchMode=yes "${USER_}@${HOST}")

vm() { local env="$1"; shift
      "${SSH[@]}" "C:\\msys64\\msys2_shell.cmd -defterm -no-start -${env} -c \"$*\""; }

cmd="${1:-status}"; shift || true
case "$cmd" in
status)
    "${SSH[@]}" "echo VM_REACHABLE & ver"
    vm clangarm64 "cd /c/cbm 2>/dev/null && git log --oneline -1 && ls -la build/c/codebase-memory-mcp.exe build/c/test-runner.exe 2>/dev/null || echo 'repo/build missing — run provision-windows.sh'"
    ;;
update)
    vm clangarm64 "cd /c/cbm && git fetch origin ${BRANCH} && git reset --hard FETCH_HEAD && git log --oneline -1"
    exec "$0" build
    ;;
build)
    vm clangarm64 "cd /c/cbm && make -j${JOBS} -f Makefile.cbm CC='ccache clang' CXX='ccache clang++' SANITIZE= cbm build/c/test-runner > /tmp/win-build.log 2>&1 && echo BUILD_OK || (echo BUILD_FAIL; tail -20 /tmp/win-build.log; exit 1)"
    ;;
test)
    [ $# -ge 1 ] || { echo "usage: win.sh test <suite...>" >&2; exit 2; }
    vm clangarm64 "cd /c/cbm && ./build/c/test-runner $* 2>&1 | tail -40"
    ;;
guards)
    vm clangarm64 "cd /c/cbm && for g in tests/windows/test_*.py; do echo \"== \\\$g ==\"; python \\\$g build/c/codebase-memory-mcp.exe 2>&1 | tail -6; done"
    ;;
smoke-install)
    # Real managed install E2E with FULL stderr visible — the exact class the
    # CI smoke Phase 8 exercises but cannot show (probe hides launcher stderr).
    vm clangarm64 "cd /c/cbm && ./build/c/codebase-memory-mcp.exe install 2>&1 | tail -25"
    ;;
sh)
    vm clangarm64 "$*"
    ;;
push-file)
    [ $# -eq 2 ] || { echo "usage: win.sh push-file <local-path> <vm-path>" >&2; exit 2; }
    # Windows OpenSSH resolves scp targets natively: use C:/... not /c/...
    dest="${2/#\/c\//C:\/}"
    scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$1" "${USER_}@${HOST}:${dest}"
    ;;
ubsan-build)
    # x86_64 (CI's exact arch) with UBSan, runs under Windows-on-ARM emulation.
    # Validated: UBSan needs no interceptors, so it builds, runs, AND reports
    # correctly under emulation. (ASan does NOT: no aarch64 runtime exists and
    # the x86_64 runtime faults in emulated process-init — ASan stays CI-only.)
    vm clang64 "cd /c/cbm && make -j${JOBS} -f Makefile.cbm CC=clang CXX=clang++ SANITIZE='-fsanitize=undefined -fno-omit-frame-pointer' build/c/test-runner > /tmp/win-ubsan-build.log 2>&1 && echo UBSAN_BUILD_OK || (echo UBSAN_BUILD_FAIL; tail -20 /tmp/win-ubsan-build.log; exit 1)"
    ;;
ubsan-test)
    [ $# -ge 1 ] || { echo "usage: win.sh ubsan-test <suite...>" >&2; exit 2; }
    vm clang64 "cd /c/cbm && ./build/c/test-runner $* 2>&1 | tail -40"
    ;;
pageheap)
    # OS-level heap verification (page-granular overflow/UAF detection) for the
    # native ARM64 test-runner — toolchain-agnostic partial ASan substitute.
    # 'on' enables full PageHeap for test-runner.exe via IFEO; 'off' removes it.
    case "${1:-}" in
    on)
        "${SSH[@]}" "reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\test-runner.exe\" /v GlobalFlag /t REG_DWORD /d 0x02000000 /f && reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\test-runner.exe\" /v PageHeapFlags /t REG_DWORD /d 0x3 /f && echo PAGEHEAP_ON"
        ;;
    off)
        "${SSH[@]}" "reg delete \"HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\test-runner.exe\" /f && echo PAGEHEAP_OFF"
        ;;
    *)  echo "usage: win.sh pageheap on|off" >&2; exit 2 ;;
    esac
    ;;
test-par)
    # Full-suite parallel run on all VM cores via the repo's parallel harness.
    vm clangarm64 "cd /c/cbm && bash scripts/run-tests-parallel.sh build/c/test-runner 2>&1 | tail -25"
    ;;
*)
    echo "unknown command: $cmd (see header for usage)" >&2; exit 2
    ;;
esac
