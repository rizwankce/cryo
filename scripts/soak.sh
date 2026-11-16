#!/bin/bash
# Soak test against the running bay: N real leases from W parallel clients (more clients than
# capsules, so leases also queue). Each lease runs a command over ssh, writes a file, checks it
# got a clean capsule, and is released. Afterwards: counters, leftovers, and the bay's open files.
# Exits non-zero when a lease failed, the bay's failed or expired counters grew, or leftovers remain.
#   scripts/soak.sh [N=200] [W=3]
# The bay's root is $CRYO_HOME if set, else ~/.cryo; the client's own files are always in ~/.cryo.
# JSON from `cryo status --json` is read with plutil (always on macOS; jq and python3 aren't).
set -u
N=${1:-200}
W=${2:-3}
ROOT=${CRYO_HOME:-$HOME/.cryo}
LOCAL=$HOME/.cryo
TIMEOUT=${SOAK_TIMEOUT:-$((N * 60 + 300))}
export PATH="$ROOT/bin:$LOCAL/bin:$PATH"
C=cryo
OUT=$(mktemp -d "${TMPDIR:-/tmp}/cryo-soak.XXXXXX")
BAY_PID=$(pgrep -f 'cryo bay start' | head -1)
[ -n "$BAY_PID" ] || { echo "no bay running"; exit 1; }

snapshot() { # label
	echo "$1: bay pid $BAY_PID, open files $(lsof -p "$BAY_PID" 2>/dev/null | wc -l | tr -d ' '), rss $(ps -o rss= -p "$BAY_PID" | tr -d ' ') KB, threads $(ps -M -p "$BAY_PID" | tail -n +2 | wc -l | tr -d ' ')"
}
field() { # json keypath
	plutil -extract "$2" raw -o - - <<<"$1" 2>/dev/null
}
# "served failed expired" from the bay's health counters; fails if the bay doesn't report them.
counter() {
	local j s f e
	j=$($C status --json 2>/dev/null) || return 1
	s=$(field "$j" health.leases_served) && f=$(field "$j" health.leases_failed) && e=$(field "$j" health.leases_expired) || return 1
	echo "$s $f $e"
}
# Every capsule the bay has is thawed (refilled and idle).
all_thawed() {
	local j n i
	j=$($C status --json 2>/dev/null) || return 1
	n=$(field "$j" capsules) || return 1
	[ "$n" -gt 0 ] || return 1
	for ((i = 0; i < n; i++)); do
		[ "$(field "$j" "capsules.$i.state")" = thawed ] || return 1
	done
}
count_dir() { find "$1" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }
ssh_hosts() { local n; n=$(grep -c '^Host ' "$LOCAL/ssh_config" 2>/dev/null); echo "${n:-0}"; }
# Lease-related files that should be back to where they started once every lease is released.
leftover_counts() {
	echo "$($C ls 2>/dev/null | grep -c .) $(ssh_hosts) $(count_dir "$LOCAL/keys") $(count_dir "$LOCAL/known_hosts") $(count_dir "$ROOT/leases") $(pgrep -f 'com.apple.Virtualization.VirtualMachine' | wc -l | tr -d ' ')"
}

J=$($C status --json 2>/dev/null) || { echo "cryo status --json failed"; exit 1; }
CAPSULES=$(field "$J" capsules) || { echo "cryo status --json has no capsules"; exit 1; }
COUNTERS=$(counter) || { echo "cryo status --json has no health counters (bay too old?); can't judge the run"; exit 1; }
read -r S0 F0 E0 <<<"$COUNTERS"
# Start from idle capsules, so the leftover counts before and after compare like for like.
for _ in $(seq 1 60); do all_thawed && break; sleep 2; done
all_thawed || { echo "capsules not all thawed after 120 s; start the soak from an idle bay"; exit 1; }
read -r -a LEFT0 <<<"$(leftover_counts)"
snapshot before | tee "$OUT/summary"
echo "capsules: $CAPSULES, bay root: $ROOT" | tee -a "$OUT/summary"

worker() { # id
	local w=$1 i lease id t0 t1 got
	while true; do
		# claim the next number under a lock (mkdir is atomic)
		until mkdir "$OUT/lock" 2>/dev/null; do sleep 0.05; done
		i=$(($(cat "$OUT/next" 2>/dev/null || echo 0) + 1)); echo $i > "$OUT/next"
		rmdir "$OUT/lock"
		[ $i -le "$N" ] || return 0
		t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
		lease=$($C lease --name "soak-$w-$i" --wait 300 2>&1)
		id=$(sed -n 's/^\(L[0-9]*\) ready.*/\1/p' <<<"$lease")
		if [ -z "$id" ]; then echo "$i FAIL lease: $lease" >> "$OUT/log"; continue; fi
		t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
		# clean capsule: no file from an earlier lease, then leave one behind for the next to not see
		got=$(ssh -F "$LOCAL/ssh_config" -o BatchMode=yes -o ConnectTimeout=20 "cryo-$id" \
			'test -e ~/soak-marker && echo DIRTY; echo '"$id"' > ~/soak-marker; cat ~/soak-marker; sw_vers -productVersion' 2>&1 </dev/null)
		if [[ "$got" == *DIRTY* ]] || ! grep -q "^$id\$" <<<"$got"; then
			echo "$i FAIL run on $id: $(tr '\n' ' ' <<<"$got")" >> "$OUT/log"
		else
			echo "$i ok $id $(perl -e "printf '%.0f', ($t1-$t0)*1000") ms" >> "$OUT/log"
		fi
		$C release "$id" >/dev/null 2>&1 || echo "$i FAIL release $id" >> "$OUT/log"
	done
}

T0=$(date +%s)
TIMED_OUT=0
for w in $(seq 1 "$W"); do worker "$w" & done
next_report=$((T0 + 30))
while [ "$(jobs -r | wc -l)" -gt 0 ]; do
	now=$(date +%s)
	if [ $((now - T0)) -ge "$TIMEOUT" ]; then
		echo "  timed out after $TIMEOUT s; stopping the clients"
		TIMED_OUT=1
		jobs -p | xargs kill 2>/dev/null
		break
	fi
	if [ "$now" -ge "$next_report" ]; then
		next_report=$((now + 30))
		echo "  $(wc -l < "$OUT/log" 2>/dev/null | tr -d ' ')/$N done, $(grep -c FAIL "$OUT/log" 2>/dev/null) failed, $((now - T0)) s"
	fi
	sleep 1
done
wait

# Let refills finish before looking for leftovers.
THAWED=0
for _ in $(seq 1 60); do all_thawed && { THAWED=1; break; }; sleep 2; done
COUNTERS=$(counter) || COUNTERS="$S0 $F0 $E0"
read -r S1 F1 E1 <<<"$COUNTERS"
read -r -a LEFT1 <<<"$(leftover_counts)"
OK=$(grep -c ' ok ' "$OUT/log" 2>/dev/null)
FAILED=$(grep -c FAIL "$OUT/log" 2>/dev/null)
{
	echo "$N leases, $W clients, $(( $(date +%s) - T0 )) s"
	echo "ok ${OK:-0}, failed ${FAILED:-0}"
	grep ' ok ' "$OUT/log" | awk '{print $4}' | sort -n | awk '{a[NR]=$1} END {print "lease wait ms: p50 " a[int(NR*0.5)] ", p90 " a[int(NR*0.9)] ", max " a[NR]}'
	echo "bay counters: served +$((S1 - S0)), failed +$((F1 - F0)), expired +$((E1 - E0))"
	echo "leftovers: cryo ls '$($C ls | tr '\n' ' ')', ssh_config hosts ${LEFT1[1]}, keys ${LEFT1[2]}, known_hosts ${LEFT1[3]}, lease folders ${LEFT1[4]} ($CAPSULES = the thawed capsules)"
	echo "VM processes: ${LEFT1[5]}"
	$C status | tail -4
} | tee -a "$OUT/summary"
snapshot after | tee -a "$OUT/summary"
grep FAIL "$OUT/log" | head -20
echo "log: $OUT/log"

# Verdict, after the summary.
reasons=()
[ "$TIMED_OUT" -eq 0 ] || reasons+=("timed out after $TIMEOUT s")
[ "${OK:-0}" -eq "$N" ] && [ "${FAILED:-0}" -eq 0 ] || reasons+=("${FAILED:-0} lease(s) failed, ${OK:-0}/$N ok")
[ "$F1" -le "$F0" ] || reasons+=("bay failed counter grew by $((F1 - F0))")
[ "$E1" -le "$E0" ] || reasons+=("bay expired counter grew by $((E1 - E0))")
[ "$THAWED" -eq 1 ] || reasons+=("capsules not all thawed 120 s after the run")
if $C ls 2>/dev/null | grep -q 'soak-'; then reasons+=("soak leases still listed by cryo ls"); fi
names=("cryo ls entries" "ssh_config hosts" "keys" "known_hosts" "lease folders" "VM processes")
for k in "${!names[@]}"; do
	[ "${LEFT1[$k]}" -le "${LEFT0[$k]}" ] || reasons+=("${names[$k]} grew from ${LEFT0[$k]} to ${LEFT1[$k]}")
done
if [ ${#reasons[@]} -gt 0 ]; then
	printf 'FAIL: %s\n' "${reasons[@]}" | tee -a "$OUT/summary"
	exit 1
fi
echo "PASS" | tee -a "$OUT/summary"
