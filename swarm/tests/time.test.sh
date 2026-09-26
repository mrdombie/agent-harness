#!/usr/bin/env bash
# time.test.sh — the two clock conversions, asserted against BOTH date
# implementations, from whichever machine this runs on.
#
# Why that matters: `date -r N` is "the time N" on BSD and "the mtime of the
# file N" on GNU, and every caller here has a `|| date` fallback that answers
# with the CURRENT time. The wrong branch therefore does not fail — it quietly
# ignores the clock a test pinned. That shipped: the suite was green on macOS
# and red on the Linux runner, reported as a stall alarm that would not fire.
#
# So the machine that is not this one is supplied by a stub. It presents the
# OTHER implementation's flag surface and computes its answers through the one
# this machine actually has, which is the only way a single runner can assert
# both.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
REAL=$(command -v date)

# Which surface does this machine speak? GNU reads "0" as a filename.
if "$REAL" -u -r 0 +%s >/dev/null 2>&1; then NATIVE=bsd; OTHER=gnu; else NATIVE=gnu; OTHER=bsd; fi
echo "this machine's date is $NATIVE; the stub will present $OTHER"

cat > "$FIX/real.sh" <<SH
R="$REAL"
if [ "$NATIVE" = bsd ]; then
  r_iso()   { "\$R" -u -r "\$1" +%Y-%m-%dT%H:%M:%SZ; }
  r_epoch() { "\$R" -u -j -f '%Y-%m-%dT%H:%M:%SZ' "\$1" +%s; }
  r_clock() { "\$R" -r "\$1" '+%H %M'; }
else
  r_iso()   { "\$R" -u -d "@\$1" +%Y-%m-%dT%H:%M:%SZ; }
  r_epoch() { "\$R" -u -d "\$1" +%s; }
  r_clock() { "\$R" -d "@\$1" '+%H %M'; }
fi
SH

# The stub. It answers only the three formats this layer asks for, and refuses
# anything else out loud — a stub that guesses would let a real defect pass.
mkdir -p "$FIX/other"
cat > "$FIX/other/date" <<SH
#!/usr/bin/env bash
. "$FIX/real.sh"
MODE=$OTHER
fmt=""; epoch=""; iso=""; want_j=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    -u) shift ;;
    -r) if [ "\$MODE" = gnu ]; then
          [ -f "\$2" ] || { echo "date: \$2: No such file or directory" >&2; exit 1; }
          echo "date: this stub is not asked for file times" >&2; exit 1
        fi
        epoch="\$2"; shift 2 ;;
    -j) [ "\$MODE" = gnu ] && { echo "date: invalid option -- 'j'" >&2; exit 1; }; want_j=1; shift ;;
    -f) [ "\$MODE" = gnu ] && { echo "date: invalid option -- 'f'" >&2; exit 1; }; shift 2; iso="\$1"; shift ;;
    -d) [ "\$MODE" = bsd ] && { echo "date: illegal time format" >&2; exit 1; }
        case "\$2" in @*) epoch="\${2#@}" ;; *) iso="\$2" ;; esac; shift 2 ;;
    +*) fmt="\${1#+}"; shift ;;
    *)  shift ;;
  esac
done
[ -n "\$epoch" ] || [ -z "\$iso" ] || epoch=\$(r_epoch "\$iso") || exit 1
[ -n "\$epoch" ] || epoch=\$("\$R" +%s)
case "\$fmt" in
  '%Y-%m-%dT%H:%M:%SZ') r_iso "\$epoch" ;;
  '%s')                 printf '%s\n' "\$epoch" ;;
  '%H %M')              r_clock "\$epoch" ;;
  *) echo "date: this stub was not taught the format '\$fmt'" >&2; exit 2 ;;
esac
SH
chmod +x "$FIX/other/date"

E=1790000000
ISO=$(bash -c ". '$FIX/real.sh'; r_iso $E")
CLOCK=$(bash -c ". '$FIX/real.sh'; r_clock $E")

check() { # <which> <PATH>
  want "$1: an epoch becomes its instant" "$ISO"   "$(PATH="$2" bash -c ". '$HERE/../time.sh'; swarm_iso $E")"
  want "$1: and back again"               "$E"     "$(PATH="$2" bash -c ". '$HERE/../time.sh'; swarm_epoch '$ISO'")"
  want "$1: the local clock reads out"    "$CLOCK" "$(PATH="$2" bash -c ". '$HERE/../time.sh'; swarm_clock $E")"
}

echo "--- this machine's own date ---"
check "$NATIVE" "$PATH"

echo "--- the implementation this machine does not have ---"
# Proof the stub is in the way: the native form must stop working under it.
if [ "$NATIVE" = bsd ]; then probe=(-u -r "$E" +%s); else probe=(-u -d "@$E" +%s); fi
if PATH="$FIX/other:$PATH" date "${probe[@]}" >/dev/null 2>&1; then
  bad "the stub is not in the way — the $NATIVE form still worked"
else
  ok "the stub refuses the $NATIVE form, as $OTHER date would"
fi
check "$OTHER" "$FIX/other:$PATH"

echo "--- an unparseable instant answers zero, it does not hang or guess ---"
want "no date at all" "0" "$(bash -c ". '$HERE/../time.sh'; swarm_epoch 'not a date'" 2>/dev/null)"

exit $FAILED
