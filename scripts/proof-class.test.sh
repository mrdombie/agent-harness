#!/usr/bin/env bash
# proof-class.test.sh — the reader that says whether a file's change is only comments,
# or only prose literals, is held to cases where the answer is known both ways: an
# honest change it must accept, and a code change dressed as one that it must refuse.
# A wrong yes ships code no test proved; a wrong no only sends the finding to a person.
#
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
TMPD=$(mktemp -d); on_exit_keep_status 'rm -rf "$TMPD"'
cp "$HERE/proof-class.py" "$TMPD/pc.py"
out=$(cd "$TMPD" && python3 -I - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("pc", "pc.py")
pc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pc)
def same(path, a, b, mask):
    return pc.canonical(path, a, mask) == pc.canonical(path, b, mask)
cases=[
 ("a.ts","const x = 1; // old\n","const x = 1; // new note\n",False,True),
 ("a.ts","const x = 1;\n","/** doc\n * more */\nconst x = 1;\n",False,True),
 ("a.ts","const x = 1; // c\n","const x = 2; // c\n",False,False),
 ("a.ts","const s = 'a // b';\n","const s = 'a // c';\n",False,False),
 ("a.tsx","return <p>Saved your draft</p>;\n","return <p>Draft saved — don't worry</p>;\n",True,True),
 ("a.tsx","return <p>Saved</p>;\n","return <p>Saved {count}</p>;\n",True,False),
 ("a.tsx",'return <Button label="Save draft" />;\n','return <Button label="Keep draft" />;\n',True,True),
 ("a.tsx",'return <a href="/a">Go</a>;\n','return <a href="/b">Go</a>;\n',True,False),
 ("a.ts",'if (role === "admin") go();\n','if (role === "user") go();\n',True,False),
 ("a.ts",'import x from "./a";\n','import x from "./b";\n',True,False),
 ("a.ts",'toast("Saved your draft");\n','toast("Draft saved");\n',True,True),
 ("a.ts",'toast("Saved your draft");\n','toast("Draft saved"); go();\n',True,False),
 ("a.ts",'const k = "save_draft";\n','const k = "keep_draft";\n',True,False),
 ("a.ts",'const m = `You have ${n} posts`;\n','const m = `You have ${n} drafts`;\n',True,True),
 ("a.ts",'const m = `You have ${n} posts`;\n','const m = `You have ${n+1} posts`;\n',True,False),
 ("a.ts",'const q = sql`select * from a`;\n','const q = sql`select * from b`;\n',True,False),
 ("a.ts",'const r = /\\/\\//; f();\n','const r = /\\/\\//; g();\n',False,False),
 ("a.py","def f():\n    # c\n    return 1\n","def f():\n    # changed\n    return 1\n",False,True),
 ("a.py","def f():\n    return 1\n","def f():\n        return 1\n",False,False),
 ("a.py","x = 1  # c\n","x = 2  # c\n",False,False),
 ("a.sh","echo hi # c\n","echo hi # d\n",False,True),
 ("a.sh","cat <<'E'\n# not a comment\nE\n","cat <<'E'\n# changed\nE\n",False,False),
 ("a.sh","echo ${#x}\n","echo ${#y}\n",False,False),
 ("a.yml","a: 1 # c\n","a: 1 # d\n",False,True),
 ("a.yml","a: \"x #1\"\n","a: \"x #2\"\n",False,False),
 ("a.java","char q = '\"'; String u = \"http://x\";\n","char q = '\"'; String u = \"http://y\";\n",False,False),
 ("a.css","a { color: red } /* c */\n","a { color: red } /* d */\n",False,True),
 ("a.json",'{"title": "Save draft"}\n','{"title": "Keep draft"}\n',True,True),
 ("a.json",'{"title": "Save draft"}\n','{"name": "Save draft"}\n',True,False),
 ("a.tsx","const f = <T,>(x: T) => x; // a\n","const f = <T,>(x: T) => x; // b\n",False,True),
 ("a.tsx","a < b && c > d; // a\n","a < b && c > d; // b\n",False,True),
 ("a.tsx","return (\n  <div>\n    {/* note */}\n    <p>Hi there</p>\n  </div>\n);\n","return (\n  <div>\n    {/* other note */}\n    <p>Hi there</p>\n  </div>\n);\n",False,True),
]
for path, a, b, mask, want in cases:
    try:
        got = same(path, a, b, mask)
    except Exception as e:
        got = "ERR %s" % e
    kind = "wording" if mask else "comment"
    verdict = "same" if want else "differs"
    tag = "OK      " if got == want else "MISMATCH"
    print("%s %s %s-only, wanted %s: %r -> %r" % (tag, path, kind, verdict, a[:60], b[:60]))
PY
)
printf '%s\n' "$out"
FAILED=$(printf '%s\n' "$out" | grep -c '^MISMATCH')
[ "$(printf '%s\n' "$out" | grep -c '^OK')" -ge 30 ] || { echo "MISMATCH the cases did not all run"; FAILED=$((FAILED+1)); }

echo "--- the settings ---"
want() { if [ "$2" = "$3" ]; then echo "OK       $1"; else echo "MISMATCH $1 — wanted '$2', got '$3'"; FAILED=$((FAILED+1)); fi; }
on() { python3 -I "$HERE/proof-class.py" enabled --kind "$1" --cfg "$2" && echo on || echo off; }
printf '{}' > "$TMPD/none.json"; printf '{"proof":{"autoAccept":false}}' > "$TMPD/off.json"
printf '{"proof":{"autoAccept":["test-only"]}}' > "$TMPD/list.json"
want "absent: on" on "$(on comment-only "$TMPD/none.json")"
want "false: off" off "$(on comment-only "$TMPD/off.json")"
want "a list: only what it names" "off on" "$(on comment-only "$TMPD/list.json") $(on test-only "$TMPD/list.json")"
suite_end "$FAILED"
