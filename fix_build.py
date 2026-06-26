#!/usr/bin/env python3
import re, os

with open('build.zig', 'r') as f:
    lines = f.readlines()

bad_lines = set()
bad_names = set()

# Find module blocks with bad paths
i = 0
while i < len(lines):
    m = re.match(r'\s*const (\w+)\s*=\s*b\.createModule', lines[i])
    if m:
        name = m.group(1)
        # Find source path
        source_path = None
        for j in range(i, min(i + 3, len(lines))):
            pm = re.search(r'path\("([^"]+)"\)', lines[j])
            if pm:
                source_path = pm.group(1)
                break
        if source_path and not os.path.exists(source_path):
            bad_names.add(name)
            # Remove entire block by brace matching
            depth = 0
            for j in range(i, len(lines)):
                depth += lines[j].count('{') - lines[j].count('}')
                if depth <= 0:
                    for x in range(i, j + 1):
                        bad_lines.add(x)
                    i = j + 1
                    break
        else:
            i += 1
    else:
        i += 1

print(f"Bad modules: {len(bad_names)}")
print(f"Bad lines from blocks: {len(bad_lines)}")

# Remove lines referencing bad module names
extra = 0
for i, line in enumerate(lines):
    if i in bad_lines:
        continue
    for n in bad_names:
        if n in line:
            bad_lines.add(i)
            extra += 1
            break

print(f"Extra bad lines (references): {extra}")

# Write result
result = [lines[i] for i in range(len(lines)) if i not in bad_lines]
with open('build.zig', 'w') as f:
    f.writelines(result)

print(f"Lines: {len(lines)} -> {len(result)}")

# Verify
content = ''.join(result)
remaining_paths = re.findall(r'path\("([^"]+)"\)', content)
remaining_missing = [p for p in remaining_paths if not os.path.exists(p)]
print(f"Remaining missing paths: {len(remaining_missing)}")

remaining_refs = [n for n in bad_names if n in content]
print(f"Remaining bad module refs: {len(remaining_refs)}")
