#!/usr/bin/env bash
# host-heavy.sh — the heavy jobs running on this host, from one ps snapshot.
#
#   . "$KIT_ROOT/scripts/host-heavy.sh"
#   host_heavy_untracked [tracked pid…]
#
# A heavy unit is a build-ticket driver, a `claude -p --name <step>` session (run directly
# or under node) or the develop-hook-red sweep. Each prints once, at its top-most process, as
#   <pid>\t<kind>\t<label>
# kind: build (label: the ticket), the session's step name (label: its --add-dir
# tree's basename, else -), hook-sweep (label: -). A unit under another heavy unit,
# or under a tracked pid, is not printed: the tracked runs are counted already.
#
# COORDINATOR_HOST_PS  the command that lists "pid ppid command" lines; default ps.

host_heavy_snapshot() {
  if [ -n "${COORDINATOR_HOST_PS:-}" ]; then "$COORDINATOR_HOST_PS"
  else ps -Ao pid=,ppid=,command= 2>/dev/null; fi
}

host_heavy_untracked() { # [tracked pid…]
  host_heavy_snapshot | awk -v tracked="$*" '
    function base(p) { sub(/.*\//, "", p); return p }
    BEGIN { n = split(tracked, t, " "); for (i = 1; i <= n; i++) if (t[i] != "") trk[t[i]] = 1 }
    $1 ~ /^[0-9]+$/ {
      pid = $1; par[pid] = $2; order[++rows] = pid; k = ""; l = "-"
      # The driver itself, run directly or through its shell: an editor or grep on the path is not.
      for (i = 3; i <= 4 && i < NF; i++) {
        if (i == 4 && $3 !~ /(^|\/)(ba|z)?sh$/) break
        if ($i ~ /(^|\/)build-ticket$/ && $(i+1) ~ /^[0-9]+$/) { k = "build"; l = $(i+1); break }
      }
      # The CLI run directly, or as a script under node (an npm install).
      c = 0
      if (base($3) == "claude") c = 4
      else if (base($3) == "node" && NF >= 4 && base($4) == "claude") c = 5
      if (k == "" && c) {
        p = 0; nm = ""; dir = ""
        for (i = c; i <= NF; i++) {
          if ($i == "-p") p = 1
          else if ($i == "--name" && i < NF) nm = $(i+1)
          else if ($i == "--add-dir" && i < NF) dir = $(i+1)
        }
        # A coordinator judge session is short and never a build.
        if (p && nm != "" && nm !~ /^judge-/) { k = nm; if (dir != "") l = base(dir) }
      }
      if (k == "") for (i = 3; i < NF; i++)
        if ($i ~ /(^|\/)develop-hook-red\.sh$/ && $(i+1) == "sweep") { k = "hook-sweep"; break }
      if (k != "") { kind[pid] = k; label[pid] = l }
    }
    END {
      for (r = 1; r <= rows; r++) {
        pid = order[r]
        if (!(pid in kind) || (pid in trk)) continue
        keep = 1; a = par[pid]
        for (d = 0; d < 64 && a != "" && a != "0"; d++) {
          if ((a in kind) || (a in trk)) { keep = 0; break }
          if (!(a in par) || par[a] == a) break
          a = par[a]
        }
        if (keep) printf "%s\t%s\t%s\n", pid, kind[pid], label[pid]
      }
    }'
}
