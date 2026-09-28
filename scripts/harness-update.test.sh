#!/usr/bin/env bash
# Fixture test for harness-update.sh.
#
# WHY THIS EXISTS
#   The duplicate detector's healthy answer is "none", which is also what a
#   broken detector prints. On the machine this was written for it printed
#   "none" ten minutes after a real duplicate had been reconciled — correct, but
#   indistinguishable from a detector that never looked. So every case below
#   plants the condition and asserts the command STOPS, rather than asserting
#   that a clean estate looks clean.
#
#   Each run uses a throwaway config directory. Nothing here reads or writes the
#   real one.
set -uo pipefail

SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness-update.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

SB="${TMPDIR:-/tmp}/harness-update-fixture-$$"
mkdir -p "$SB"
trap 'rm -rf "$SB"' EXIT
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# Build a config dir. $1 = name, $2 = enabledPlugins JSON, $3 = installed JSON.
make_cfg() {
  local d="$SB/$1"; mkdir -p "$d/plugins/marketplaces"
  printf '{ "enabledPlugins": %s }\n' "$2" > "$d/settings.json"
  printf '{ "plugins": %s }\n' "$3" > "$d/plugins/installed_plugins.json"
  printf '%s' "$d"
}

INST='{ "superpowers@a": [{"version":"6.3.0","lastUpdated":"2026-09-07"}],
        "superpowers@b": [{"version":"6.4.1","lastUpdated":"2026-09-22"}],
        "other@c":       [{"version":"1.0.0","lastUpdated":"2026-09-01"}] }'

run() { # <config dir> [args...] -> stdout; rc in RC
  local d=$1; shift
  RC=0
  CLAUDE_CONFIG_DIR="$d" bash "$SUT" "$@" 2>&1 || RC=$?
}

echo "harness-update fixture"

# --- 1. THE PLANT: two enabled copies of one plugin ---------------------------
d=$(make_cfg dup '{ "superpowers@a": true, "superpowers@b": true, "other@c": true }' "$INST")
out=$(run "$d" --check; :); run "$d" --check >/dev/null 2>&1
[ "$RC" -ne 0 ] && ok "a duplicate stops the run" || bad "a duplicate stops the run (rc $RC)"
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" --check 2>&1)
printf '%s' "$out" | grep -q 'ENABLED TWICE  superpowers@a' \
  && ok "it names the first copy" || bad "it names the first copy"
printf '%s' "$out" | grep -q 'ENABLED TWICE  superpowers@b' \
  && ok "it names the second copy" || bad "it names the second copy"
printf '%s' "$out" | grep -q '6.3.0' && printf '%s' "$out" | grep -q '6.4.1' \
  && ok "it gives both versions, so the operator can choose" \
  || bad "it gives both versions"
printf '%s' "$out" | grep -q 'Nothing was changed' \
  && ok "it says nothing was changed" || bad "it says nothing was changed"

# --- 2. The reconciled estate is NOT a duplicate ------------------------------
# One copy disabled is the fix. If this still reported a duplicate, the command
# would refuse to run for ever after a correct reconciliation.
d=$(make_cfg fixed '{ "superpowers@a": false, "superpowers@b": true, "other@c": true }' "$INST")
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" --check 2>&1)
printf '%s' "$out" | grep -qE 'DUPLICATES' && printf '%s' "$out" | grep -A1 'DUPLICATES' | grep -q 'none' \
  && ok "a disabled second copy is not a duplicate" \
  || bad "a disabled second copy is not a duplicate"
printf '%s' "$out" | grep -q 'Nothing was changed' \
  && bad "the reconciled estate does not stop the run" \
  || ok "the reconciled estate does not stop the run"

# --- 3. It stops BEFORE acting ------------------------------------------------
# A duplicate must stop the run in apply mode too, not only under --check.
d=$(make_cfg dup2 '{ "superpowers@a": true, "superpowers@b": true }' "$INST")
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "apply mode stops on a duplicate too" || bad "apply mode stops on a duplicate too (rc $rc)"
printf '%s' "$out" | grep -q 'Applying' \
  && bad "it does not reach the applying step" \
  || ok "it does not reach the applying step"

# --- 4. A clean, level estate exits 0 -----------------------------------------
# Without this the command could satisfy every case above by always failing.
d=$(make_cfg clean '{ "other@c": true }' '{ "other@c": [{"version":"1.0.0","lastUpdated":"2026-09-01"}] }')
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" --check 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "a level estate exits 0" || bad "a level estate exits 0 (rc $rc, out: $(printf '%s' "$out" | tail -2 | tr '\n' ' '))"

# --- 5. It reports before it decides ------------------------------------------
# The operator reads what is about to change; a command that acts first is the
# thing this replaces.
d=$(make_cfg order '{ "superpowers@a": true, "superpowers@b": true }' "$INST")
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" 2>&1)
first=$(printf '%s' "$out" | grep -nE 'MARKETPLACES|STOP' | head -1 | cut -d: -f2)
[ "$first" = "MARKETPLACES" ] && ok "the report comes before the verdict" \
                              || bad "the report comes before the verdict (saw '$first')"

# --- 5b. A COMMIT THAT MOVED WITHOUT A VERSION BUMP IS STILL BEHIND -----------
# `claude plugin update` compares the manifest VERSION, not the commit, and exits
# 0 saying "already at the latest version" when only the commit moved. The estate
# then sits behind while the command reports it current — measured on this kit's
# own plugin, eight commits behind at an unchanged 0.2.0.
#
# The plant is the disagreement itself: an installed sha that is not the clone's
# HEAD. Asserting that a matching pair looks fine would pass on a probe that
# never read either value.
stale_fixture() { # $1 = drifted|level|catalogue|scoped -> echoes the config dir
  local kind=$1
  local d="$SB/stale-$kind"
  mkdir -p "$d/plugins/marketplaces"
  local clone="$d/plugins/marketplaces/mkt"
  mkdir -p "$clone/.claude-plugin"
  git init -q -b main "$clone"
  # A marketplace whose entry is a PATH is the plugin's own repo, so its HEAD is
  # comparable. One whose entry is a url is a catalogue: its HEAD says nothing
  # about the plugin, and comparing them is a confident false positive.
  if [ "$kind" = catalogue ]; then
    printf '{ "plugins": [ { "name": "thing", "source": { "source": "url", "url": "https://example.invalid/thing.git" } } ] }\n' \
      > "$clone/.claude-plugin/marketplace.json"
  else
    printf '{ "plugins": [ { "name": "thing", "source": "./" } ] }\n' \
      > "$clone/.claude-plugin/marketplace.json"
    printf '{ "name": "thing", "version": "%s" }\n' "$([ "$kind" = scoped ] && echo 0.4.0 || echo 0.2.0)" \
      > "$clone/.claude-plugin/plugin.json"
  fi
  git -C "$clone" add -A
  git -C "$clone" -c user.email=t@f.local -c user.name=f commit -q -m one
  local first; first=$(git -C "$clone" rev-parse HEAD)
  git -C "$clone" -c user.email=t@f.local -c user.name=f commit -q --allow-empty -m two
  local head; head=$(git -C "$clone" rev-parse HEAD)

  printf '{ "enabledPlugins": { "thing@mkt": true } }\n' > "$d/settings.json"
  if [ "$kind" = scoped ]; then
    # TWO records for one plugin. `claude plugin update` moves the user one
    # only, so a stale project record hides behind a healthy user record — and
    # a probe that reads .[0] reports neither.
    printf '{ "plugins": { "thing@mkt": [
      {"scope":"user","version":"0.4.0","gitCommitSha":"%s","lastUpdated":"2026-09-24"},
      {"scope":"project","version":"0.2.0","gitCommitSha":"%s","lastUpdated":"2026-09-20"} ] } }\n' \
      "$head" "$first" > "$d/plugins/installed_plugins.json"
  else
    local recorded=$head
    [ "$kind" = level ] || recorded=$first
    printf '{ "plugins": { "thing@mkt": [{"scope":"user","version":"0.2.0","gitCommitSha":"%s","lastUpdated":"2026-09-20"}] } }\n' \
      "$recorded" > "$d/plugins/installed_plugins.json"
  fi
  printf '%s' "$d"
}

d=$(stale_fixture drifted)
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" --check 2>&1); rc=$?
printf '%s' "$out" | grep -q 'STALE INSTALLS' \
  && ok "the report has a stale-installs section" || bad "the report has a stale-installs section"
printf '%s' "$out" | grep -A2 'STALE INSTALLS' | grep -q 'thing@mkt' \
  && ok "a commit that moved without a version bump is named" \
  || bad "a commit that moved without a version bump is named (saw: $(printf '%s' "$out" | grep -A2 'STALE INSTALLS' | tr '\n' ' '))"
printf '%s' "$out" | grep -qiE 'bump it in the plugin.s manifest' \
  && ok "and it says what to do about it" || bad "and it says what to do about it"
[ "$rc" -ne 0 ] && ok "and --check exits non-zero on it" || bad "and --check exits non-zero on it (rc $rc)"

# The control. Without it the probe could satisfy every case by always reporting.
d=$(stale_fixture level)
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" --check 2>&1)
printf '%s' "$out" | grep -A1 'STALE INSTALLS' | grep -q 'none' \
  && ok "a matching sha is not reported as stale" \
  || bad "a matching sha is not reported as stale (saw: $(printf '%s' "$out" | grep -A1 'STALE INSTALLS' | tr '\n' ' '))"

# --- 5c. A CATALOGUE MARKETPLACE IS NOT THE PLUGIN'S REPO ---------------------
# THE FALSE POSITIVE. A marketplace whose entries point at other repositories has
# a HEAD of its own that has nothing to do with any of them. Measured 2026-09-24:
# an earlier version of this probe reported a plugin as ten commits stale against
# a clone that has never contained it, and that reached the operator as a finding.
d=$(stale_fixture catalogue)
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" --check 2>&1)
printf '%s' "$out" | grep -A1 'STALE INSTALLS' | grep -q 'none' \
  && ok "a catalogue marketplace's HEAD is not compared" \
  || bad "a catalogue marketplace's HEAD is not compared (saw: $(printf '%s' "$out" | grep -A2 'STALE INSTALLS' | tr '\n' ' '))"

# --- 5d. EVERY RECORD, NOT THE FIRST -----------------------------------------
# One plugin, two scopes: the user record current, the project record behind.
# Reading .[0] reports neither, because the healthy one is first.
d=$(stale_fixture scoped)
out=$(CLAUDE_CONFIG_DIR="$d" bash "$SUT" --check 2>&1)
printf '%s' "$out" | grep -q 'project' \
  && ok "a stale record behind a healthy one is still found" \
  || bad "a stale record behind a healthy one is still found (saw: $(printf '%s' "$out" | grep -A2 'STALE INSTALLS' | tr '\n' ' '))"
printf '%s' "$out" | grep -q 'update did not reach this scope' \
  && ok "and it says the update never reached that scope" \
  || bad "and it says the update never reached that scope"
printf '%s' "$out" | grep -q 'version did not move' \
  && bad "and does not blame the manifest version, which did move" \
  || ok "and does not blame the manifest version, which did move"

# --- 6. THE PIN DOES NOT MOVE PAST A RED KIT ----------------------------------
# The one change that decides what a BUILD runs. A pin that moves past a kit
# whose own suites fail is the defect this whole step exists to prevent, so it is
# proved by planting a failing suite at the target ref — not by reading the code.
#
# A stub `claude` keeps the run away from the real plugin estate: without it the
# apply path would call the actual CLI and update this machine.
kit_fixture() { # $1 = "pass" | "fail" [$2 = marketplace name] -> echoes the config dir
  # Two statements, not one: in `local a=$1 b="$SB/x-$a"`, bash expands the
  # right-hand sides before the names become local, so $a is unbound under set -u
  # and the fixture silently builds nothing — which then compares empty to empty
  # and reports PASS. Cost two false passes before it was noticed.
  local kind=$1
  local root="$SB/kit-$kind-${2:-own}"
  mkdir -p "$root/plugins/marketplaces" "$root/bin"
  printf '{ "enabledPlugins": {} }\n' > "$root/settings.json"

  local origin="$root/origin.git" work="$root/work"
  git init -q --bare -b main "$origin"
  git clone -q "$origin" "$work" 2>/dev/null
  mkdir -p "$work/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$work/scripts/a.test.sh"
  git -C "$work" add -A
  git -C "$work" -c user.email=t@f.local -c user.name=f commit -qm first
  git -C "$work" push -q origin main
  local base; base=$(git -C "$work" rev-parse HEAD)

  # The second commit is what the install would move TO.
  if [ "$kind" = fail ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$work/scripts/a.test.sh"
  else
    printf '#!/usr/bin/env bash\nexit 0\n' > "$work/scripts/b.test.sh"
  fi
  git -C "$work" add -A
  git -C "$work" -c user.email=t@f.local -c user.name=f commit -qm second
  git -C "$work" push -q origin main

  # The marketplace clone the command reads, named after the PLUGIN, which the
  # command takes from its own manifest.
  local mkt="${2:-$KITNAME}"
  git clone -q "$origin" "$root/plugins/marketplaces/$mkt" 2>/dev/null
  printf '{ "plugins": { "%s@%s": [{"scope":"user","version":"0.0.1","gitCommitSha":"%s"}] } }\n' \
    "$KITNAME" "$mkt" "$base" > "$root/plugins/installed_plugins.json"

  # A `claude` that records what it was asked to update, so the assertions read
  # the ACTION and not just the prose. A real CLI here would touch this machine.
  cat > "$root/bin/claude" <<CLAUDE
#!/bin/sh
[ "\$1" = plugin ] && [ "\$2" = update ] && echo "\$3" >> "$root/updated.log"
exit 0
CLAUDE
  chmod +x "$root/bin/claude"
  printf '%s' "$root"
}

KITNAME=$(jq -r '.name' "$(cd "$(dirname "$SUT")/.." && pwd)/.claude-plugin/plugin.json")

# --- the kit's suites are RED at the target ref -------------------------------
r=$(kit_fixture fail)
out=$(PATH="$r/bin:$PATH" CLAUDE_CONFIG_DIR="$r" bash "$SUT" 2>&1); rc=$?
printf '%s' "$out" | grep -q 'suites fail' \
  && ok "a failing kit suite is reported" || bad "a failing kit suite is reported"
printf '%s' "$out" | grep -q 'NOT being updated' \
  && ok "and it says the kit is NOT being updated" || bad "and it says so plainly"
grep -q "$KITNAME@$KITNAME" "$r/updated.log" 2>/dev/null \
  && bad "the red kit was installed anyway" || ok "the red kit was never handed to the CLI"
[ "$rc" -ne 0 ] && ok "and the run exits non-zero" || bad "and the run exits non-zero (rc $rc)"

# --- the control: GREEN at the target ref, so it must actually update ---------
# Without this every case above is satisfied by a command that updates nothing.
r=$(kit_fixture pass)
out=$(PATH="$r/bin:$PATH" CLAUDE_CONFIG_DIR="$r" bash "$SUT" 2>&1)
grep -q "$KITNAME@$KITNAME" "$r/updated.log" 2>/dev/null \
  && ok "a passing kit suite IS handed to the CLI" || bad "a passing kit suite IS handed to the CLI"
printf '%s' "$out" | grep -q 'testing the kit at' \
  && ok "and the test gate ran before it" || bad "and the test gate ran before it"

# --- the marketplace is NOT assumed to be named after the plugin ------------
# installed_plugins.json keys are <plugin>@<marketplace>, and on a normal machine
# every other plugin is name@claude-plugins-official. Assuming they match skipped
# the whole test gate: measured 2026-09-28, a marketplace called `acme-tools`
# printed "no local clone of the kit's marketplace to compare against" and then
# installed the red kit with no suite run. This is that case.
r=$(kit_fixture fail acme-tools)
out=$(PATH="$r/bin:$PATH" CLAUDE_CONFIG_DIR="$r" bash "$SUT" 2>&1)
grep -q "$KITNAME@acme-tools" "$r/updated.log" 2>/dev/null \
  && bad "a red kit in a differently-named marketplace was installed anyway" \
  || ok "a red kit is held whatever the marketplace is called"
printf '%s' "$out" | grep -q 'testing the kit at' \
  && ok "and the test gate found the clone to test" || bad "the gate could not find the clone"

r=$(kit_fixture pass acme-tools)
out=$(PATH="$r/bin:$PATH" CLAUDE_CONFIG_DIR="$r" bash "$SUT" 2>&1)
grep -q "$KITNAME@acme-tools" "$r/updated.log" 2>/dev/null \
  && ok "and a green one is still installed from there" || bad "a green kit was not installed"

# --- the second pin is gone ---------------------------------------------------
# It used to rewrite kit.ref in the consuming repo's harness.json. Nothing may
# write that key any more: a second pin beside the marketplace's is the exact
# duplication this release is removing.
grep -q "kit.ref = " "$SUT" && bad "the script still writes kit.ref into harness.json" \
                            || ok "no second pin is written into any repo's harness.json"

echo
[ "$fail" -eq 0 ] && echo "harness-update fixture: all checks hold" \
                  || echo "harness-update fixture: FAILURES"
exit "$fail"
