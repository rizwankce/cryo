#!/bin/bash
# Checks the capsule fence (the pf rules in Sources/CryoBay/Install.swift) from inside a
# leased guest: DNS and internet work, while the host, the LAN and other capsules stay out of
# reach. Run on the bay's Mac, against a lease the bay already serves:
#   cryo lease --name fence      # prints "L<n> ready ..."
#   scripts/check-fence.sh L<n>
#   cryo release L<n>
# Prints PASS/FAIL per check and exits non-zero if any check fails.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: scripts/check-fence.sh <lease-id>" >&2; exit 2; }
lease=$1
export PATH="$HOME/.cryo/bin:$PATH"
root=${CRYO_HOME:-$HOME/.cryo}
failed=0

# Runs a command in the guest; its exit status is the command's.
guest() { cryo ssh "$lease" "$1" </dev/null; }
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failed=1; }
# expect_open / expect_blocked <label> <guest command>
expect_open() { if guest "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }
expect_blocked() { if guest "$2" >/dev/null 2>&1; then fail "$1"; else pass "$1"; fi; }

# The guest's gateway is 10.77.N.1 (CapsuleNetwork.gateway): the host's side of its vmnet network.
gw=$(guest "route -n get default 2>/dev/null | awk '/gateway:/ {print \$2}'") || true
if [[ ! "$gw" =~ ^10\.77\.([0-9]+)\.1$ ]]; then
	echo "can't read the guest's gateway over \`cryo ssh $lease\` (got '$gw')" >&2
	exit 1
fi
own=${BASH_REMATCH[1]}
iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}') || true
lan=$(ipconfig getifaddr "${iface:-en0}" 2>/dev/null) || true
router=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}') || true
echo "lease $lease: guest 10.77.$own.2, gateway $gw, host LAN ${lan:-?}, LAN router ${router:-?}"

expect_open "guest -> DNS lookup apple.com" "dscacheutil -q host -a name apple.com | grep -q ip_address"
expect_open "guest -> internet https://www.apple.com" "curl -fsS -m 10 -o /dev/null https://www.apple.com"
expect_open "guest -> gateway $gw:53 (vmnet's DNS proxy)" "nc -z -G 2 $gw 53"
expect_blocked "guest -> gateway $gw:22" "nc -z -G 2 $gw 22"
if [ -n "$lan" ]; then
	expect_blocked "guest -> host LAN IP $lan:22" "nc -z -G 2 $lan 22"
else
	fail "host LAN IP unknown (no address on ${iface:-en0})"
fi
if [ -n "$router" ]; then
	expect_blocked "guest -> LAN router $router:80" "nc -z -G 2 $router 80"
fi
expect_blocked "guest -> NAT VM range 192.168.64.1:53" "nc -z -G 2 192.168.64.1 53"

# Other capsules, from their manifests: their guest's sshd and port 53 must be out of reach.
others=0
for m in "$root"/capsules/*/manifest.json; do
	[ -e "$m" ] || continue
	n=$(/usr/bin/plutil -extract network.subnet raw -o - "$m" 2>/dev/null) || continue
	[ "$n" != "$own" ] || continue
	others=$((others + 1))
	expect_blocked "guest -> other capsule's guest 10.77.$n.2:22" "nc -z -G 2 10.77.$n.2 22"
	expect_blocked "guest -> other capsule's guest 10.77.$n.2:53" "nc -z -G 2 10.77.$n.2 53"
done
[ "$others" -gt 0 ] || echo "SKIP  other capsules: no other capsule manifest under $root/capsules"

if [ "$failed" -ne 0 ]; then echo "fence: FAIL"; exit 1; fi
echo "fence: PASS"
