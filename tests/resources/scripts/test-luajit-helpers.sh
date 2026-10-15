#!/usr/bin/env bash
set -eu

repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
script_dir="$repo_root/tests/resources/scripts"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/crates"
cat > "$tmp/crates/licensed.rs" <<'EOF'
// SPDX-License-Identifier: LicenseRef-SEL
fn removed() {}
EOF
cat > "$tmp/crates/mixed.rs" <<'EOF'
fn mixed() {}
// SPDX-SnippetBegin
// SPDX-License-Identifier: LicenseRef-SEL
fn private() {}
// SPDX-SnippetEnd
fn retained() {}
// SPDX-SnippetBegin
// SPDX-License-Identifier: MIT
fn public() {}
// SPDX-SnippetEnd
EOF
cat > "$tmp/crates/unchanged.rs" <<'EOF'
fn unchanged() {}
EOF

luajit "$repo_root/resources/scripts/ossify.lua" --dry-run --verbose "$tmp/crates" > "$tmp/dry-run.out"
grep -F "Would remove file: $tmp/crates/licensed.rs" "$tmp/dry-run.out" >/dev/null
grep -F "Would remove 1 snippet(s) from: $tmp/crates/mixed.rs" "$tmp/dry-run.out" >/dev/null
grep -F -- "- 1 files would be completely removed" "$tmp/dry-run.out" >/dev/null
grep -F -- "- 1 proprietary snippets would be removed from 1 files" "$tmp/dry-run.out" >/dev/null
test -f "$tmp/crates/licensed.rs"
grep -F "LicenseRef-SEL" "$tmp/crates/mixed.rs" >/dev/null

luajit "$repo_root/resources/scripts/ossify.lua" "$tmp/crates" > "$tmp/ossify.out"
test ! -e "$tmp/crates/licensed.rs"
cat > "$tmp/mixed.expected" <<'EOF'
fn mixed() {}
fn retained() {}
// SPDX-SnippetBegin
// SPDX-License-Identifier: MIT
fn public() {}
// SPDX-SnippetEnd
EOF
cmp "$tmp/mixed.expected" "$tmp/crates/mixed.rs"

cat > "$tmp/imap.log" <<'EOF'
2025-01-02T03:04:06Z TRACE Raw IMAP output sent remoteIp = 10.0.0.2, remotePort = 143, contents = "A1 OK done\r\n"
2025-01-02T03:04:05Z TRACE Raw IMAP input received remoteIp = 10.0.0.2, remotePort = 143, contents = "A1 LOGIN user pass\r\n"
2025-01-02T03:04:07Z TRACE Raw IMAP input received remoteIp = 10.0.0.3, remotePort = 993, contents = "A2 NO bad\nline\tX"
2025-01-02T03:04:08Z TRACE Raw IMAP malformed sample
EOF
luajit "$script_dir/imap-log-parser.lua" --verbose --json --output "$tmp/imap.txt" "$tmp/imap.log" > "$tmp/parser.out"
grep -F "Found 4 Raw IMAP lines" "$tmp/parser.out" >/dev/null
grep -F "Successfully parsed 3 entries" "$tmp/parser.out" >/dev/null
grep -F "Warning: Could not parse line 4:" "$tmp/parser.out" >/dev/null
cat > "$tmp/imap.expected" <<'EOF'
IMAP Transaction Log Analysis
==================================================

Connection: 10.0.0.2:143
------------------------------
Total messages: 2
Duration: 2025-01-02T03:04:05Z to 2025-01-02T03:04:06Z

[2025-01-02T03:04:05Z] C: A1 LOGIN user pass
[2025-01-02T03:04:06Z] S: A1 OK done

==================================================

Connection: 10.0.0.3:993
------------------------------
Total messages: 1
Duration: 2025-01-02T03:04:07Z to 2025-01-02T03:04:07Z

[2025-01-02T03:04:07Z] C: A2 NO bad
line	X

==================================================

EOF
cmp "$tmp/imap.expected" "$tmp/imap.txt"
luajit - "$script_dir/vendor/json.lua" "$tmp/imap.json" <<'LUA'
local json = dofile(arg[1])
local file = assert(io.open(arg[2], "rb"))
local result = assert(json.decode(file:read("*a")))
file:close()
local first = result["10.0.0.2:143"]
assert(#first == 2 and first[1].timestamp == "2025-01-02T03:04:05Z")
assert(first[1].contents == "A1 LOGIN user pass\r\n")
assert(first[2].remote_port == 143 and first[2].direction == "output sent")
assert(result["10.0.0.3:993"][1].contents == "A2 NO bad\nline\tX")
LUA

if luajit "$script_dir/imap-log-parser.lua" "$tmp/missing.log" > "$tmp/missing.out"; then
  echo "missing input unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  test "$status" -eq 1
fi
grep -Fx "Error: File '$tmp/missing.log' not found" "$tmp/missing.out" >/dev/null

if luajit "$script_dir/imap-log-parser.lua" --output "$tmp/missing-dir/out.txt" "$tmp/imap.log" > "$tmp/write-error.out"; then
  echo "invalid output path unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  test "$status" -eq 1
fi
grep -Fx "Error writing output: [Errno 2] No such file or directory: '$tmp/missing-dir/out.txt'" "$tmp/write-error.out" >/dev/null

echo "LuaJIT helper tests passed"
