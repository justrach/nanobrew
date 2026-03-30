#!/bin/bash
set -e

RUNS=3  # runs per test for median

ms() { echo $(( ($2 - $1) / 1000000 )); }
median3() { echo "$1 $2 $3" | tr ' ' '\n' | sort -n | head -2 | tail -1; }

# Clean slate for nanobrew between tests
nb_clean() {
    nb remove --deb $@ >/dev/null 2>&1 || true
    rm -rf /opt/nanobrew/cache/apt/*.nbix 2>/dev/null || true
    rm -rf /opt/nanobrew/cache/blobs/* 2>/dev/null || true
}

apt_clean() {
    apt-get remove -y $@ >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
    apt-get clean >/dev/null 2>&1
}

# Benchmark one tool, one package set, N runs → prints median
# Usage: bench_apt "curl wget" 3
bench_apt() {
    local pkgs="$1" runs="$2"
    local times=()
    for i in $(seq 1 $runs); do
        apt_clean $pkgs
        local t1=$(date +%s%N)
        apt-get install -y $pkgs >/dev/null 2>&1
        local t2=$(date +%s%N)
        times+=( $(ms $t1 $t2) )
    done
    median3 ${times[0]} ${times[1]} ${times[2]}
}

bench_nb_cold() {
    local pkgs="$1" runs="$2"
    local times=()
    for i in $(seq 1 $runs); do
        nb_clean $pkgs
        local t1=$(date +%s%N)
        nb install --deb --skip-postinst $pkgs 2>/dev/null || true
        local t2=$(date +%s%N)
        times+=( $(ms $t1 $t2) )
    done
    median3 ${times[0]} ${times[1]} ${times[2]}
}

bench_nb_warm() {
    local pkgs="$1" runs="$2"
    # Seed the cache with one cold install
    nb_clean $pkgs
    nb install --deb --skip-postinst $pkgs >/dev/null 2>&1 || true
    local times=()
    for i in $(seq 1 $runs); do
        nb remove --deb $pkgs >/dev/null 2>&1 || true
        local t1=$(date +%s%N)
        nb install --deb --skip-postinst $pkgs 2>/dev/null || true
        local t2=$(date +%s%N)
        times+=( $(ms $t1 $t2) )
    done
    median3 ${times[0]} ${times[1]} ${times[2]}
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  nanobrew vs apt-get — reproducible benchmark suite        ║"
echo "║  $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
echo "║  $(uname -m) | $(nproc) cores | ${RUNS} runs per test (median)       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Test suites ──────────────────────────────────────────────
declare -a SUITE_NAMES=( 
    "small (curl wget)"
    "medium (curl wget tree jq htop tmux)"
    "dev-tools (git vim build-essential)"
    "server (nginx redis-server postgresql-client)"
)
declare -a SUITE_PKGS=(
    "curl wget"
    "curl wget tree jq htop tmux"
    "git vim build-essential"
    "nginx redis-server postgresql-client"
)

printf "%-38s %10s %10s %10s %8s\n" "TEST" "apt-get" "nb cold" "nb warm" "speedup"
printf "%-38s %10s %10s %10s %8s\n" "----" "-------" "-------" "-------" "-------"

for idx in "${!SUITE_NAMES[@]}"; do
    name="${SUITE_NAMES[$idx]}"
    pkgs="${SUITE_PKGS[$idx]}"

    echo "" >&2
    echo ">>> Running: $name ..." >&2

    apt_ms=$(bench_apt "$pkgs" $RUNS)
    nb_cold_ms=$(bench_nb_cold "$pkgs" $RUNS)
    nb_warm_ms=$(bench_nb_warm "$pkgs" $RUNS)

    if [ "$nb_warm_ms" -gt 0 ] 2>/dev/null; then
        speedup=$(echo "scale=1; $apt_ms / $nb_warm_ms" | bc 2>/dev/null || echo "?")
    else
        speedup="?"
    fi

    printf "%-38s %8sms %8sms %8sms %7sx\n" "$name" "$apt_ms" "$nb_cold_ms" "$nb_warm_ms" "$speedup"
done

echo ""
echo "Notes:"
echo "  - apt-get has pre-cached index from 'apt-get update' in Docker build"
echo "  - nb cold = first run (fetches Packages.gz + downloads all .debs)"
echo "  - nb warm = cached NBIX index + cached .deb blobs (--skip-postinst)"
echo "  - speedup = apt-get time / nb warm time"
