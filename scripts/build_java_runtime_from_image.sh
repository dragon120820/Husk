#!/bin/bash
# 从 Lineage qcow2 系统镜像中提取 Husk 的 Java 运行时所需文件(APEX 内容)
#
# 目标: 生成 build/java-runtime/, 结构模仿 Android 的 /apex 挂载树:
#   com.android.art/javalib/{core-oj,core-libart,okhttp,bouncycastle,apache-xml}.jar
#   com.android.art/lib64/{libandroidio,libbase,libc++,libexpat,libjavacore,libnativehelper,libopenjdk}.so
#   com.android.i18n/javalib/core-icu4j.jar
#   com.android.i18n/lib64/{libicu,libicui18n,libicuuc,libicu_jni,libandroidicu}.so
#   com.android.i18n/etc/icu/...
#   com.android.tzdata/etc/...
#   com.android.conscrypt/javalib/conscrypt.jar
#   com.android.conscrypt/lib64/{libjavacrypto,libcrypto,libssl}.so
#
# 用法: build_java_runtime_from_image.sh <vda.qcow2>
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:?usage: build_java_runtime_from_image.sh <vda.qcow2|vda.raw>}"
OUT="$HUSK_ROOT/build/java-runtime"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> converting the image to raw"
RAW="$IMG"
case "$IMG" in *.qcow2) qemu-img convert -O raw "$IMG" "$WORK/vda.raw"; RAW="$WORK/vda.raw" ;; esac

# --- 从镜像的 system 逻辑分区里抽出 system.img (复用 build_android_system.sh 的逻辑) ---
echo "==> unpacking the super partition"
python3 - "$RAW" "$WORK" <<'EOF'
import struct, subprocess, sys
raw, work = sys.argv[1], sys.argv[2]
out = subprocess.run(['gpt', '-r', 'show', raw], capture_output=True, text=True).stdout
start = [int(l.split()[0]) for l in out.splitlines() if l.split()[2:4] == ['2', 'GPT']][0]
base = start * 512
f = open(raw, 'rb')
f.seek(base + 12288); h = f.read(256)
magic, _, _, hsize = struct.unpack_from('<IHHI', h, 0)
assert magic == 0x414C5030, 'no logical partition metadata'
o = 12 + 32; tsize = struct.unpack_from('<I', h, o)[0]; o += 4 + 32
descs = [struct.unpack_from('<III', h, o + 12 * i) for i in range(4)]
f.seek(base + 12288 + hsize); T = f.read(tsize)
(po, pn, ps), (eo, en, es) = descs[0], descs[1]
ext = [struct.unpack_from('<QIQI', T, eo + es * i) for i in range(en)]
for i in range(pn):
    e = T[po + ps * i:po + ps * (i + 1)]
    name = e[:36].split(b'\0')[0].decode(); _, fi, ne, _ = struct.unpack_from('<IIII', e, 36)
    if name != 'system': continue
    with open(work + '/system.img', 'wb') as w:
        for j in range(fi, fi + ne):
            nsec, _, data, _ = ext[j]
            f.seek(base + data * 512); left = nsec * 512
            while left:
                b = f.read(min(left, 64 << 20)); w.write(b); left -= len(b)
EOF

[ -f "$WORK/system.img" ] || { echo "ERROR: system.img not extracted" >&2; exit 1; }

# --- 挂载 system.img, 定位 APEX ---
# 注意: debugfs 只读方式访问 ext4, 不用 mount (CI 里通常无 root)
DEBUGFS="$(command -v debugfs || echo /opt/homebrew/opt/e2fsprogs/sbin/debugfs)"
[ -x "$DEBUGFS" ] || { echo "ERROR: debugfs not found (brew install e2fsprogs)" >&2; exit 1; }

echo "==> listing APEX files in system"
# Android 11+ 把 APEX 放在 /system/apex/*.apex (或 .capex / .apex 目录)
"$DEBUGFS" -R "ls -l /system/apex" "$WORK/system.img" 2>/dev/null > "$WORK/apexlist.txt" || true
cat "$WORK/apexlist.txt"

mkdir -p "$WORK/apex"
# 逐个抽出 /system/apex 下的 apex 文件
python3 - "$WORK/apexlist.txt" "$WORK" <<'EOF'
import re, sys, subprocess, os
lst, work = sys.argv[1], sys.argv[2]
names = []
for line in open(lst, errors='replace'):
    m = re.search(r'(com\.android\.[A-Za-z0-9_]+\.(?:apex|capex))', line)
    if m: names.append(m.group(1))
names = sorted(set(names))
print('apex files:', names)
for n in names:
    subprocess.run(['dd'], capture_output=True)  # noop
open(work + '/apex_names.txt', 'w').write('\n'.join(names))
EOF

APEZ="$(cat "$WORK/apex_names.txt")"
[ -n "$APEZ" ] || { echo "ERROR: no apex found in /system/apex" >&2; exit 1; }

echo "==> dumping apex files"
while read -r n; do
    [ -n "$n" ] || continue
    "$DEBUGFS" -R "dump /system/apex/$n $WORK/apex/$n" "$WORK/system.img" 2>/dev/null || true
done <<< "$APEZ"

rm -rf "$OUT"; mkdir -p "$OUT"

# --- 解包 APEX: 一个 apex 是 erofs 镜像 (apex_payload.img), 包在 apex 容器里 ---
# com.android.art.capex / .apex : 老格式是 zip 含 apex_payload.img (ext4/erofs);
# 新格式 (.capex) 是 zip 含 original_apex -> 再是 zip 含 apex_payload.img
echo "==> extracting apex payloads"
python3 - "$WORK" "$OUT" <<'EOF'
import sys, os, zipfile, subprocess, shutil, struct
work, out = sys.argv[1], sys.argv[2]

def find_in_apex(apex_path):
    """返回 apex 内 apex_payload.img 的字节, 处理 .capex 的嵌套 zip."""
    with open(apex_path, 'rb') as f:
        head = f.read(4)
    if head[:2] != b'PK':
        return None, None
    outer = zipfile.ZipFile(apex_path)
    names = outer.namelist()
    if 'original_apex' in names:
        inner_bytes = outer.read('original_apex')
        import io
        inner = zipfile.ZipFile(io.BytesIO(inner_bytes))
        return inner.read('apex_payload.img'), inner
    if 'apex_payload.img' in names:
        return outer.read('apex_payload.img'), outer
    return None, None

targets = {
    'com.android.art':   ['javalib/core-oj.jar','javalib/core-libart.jar','javalib/okhttp.jar',
                          'javalib/bouncycastle.jar','javalib/apache-xml.jar',
                          'lib64/libandroidio.so','lib64/libbase.so','lib64/libc++.so','lib64/libexpat.so',
                          'lib64/libjavacore.so','lib64/libnativehelper.so','lib64/libopenjdk.so'],
    'com.android.i18n':  ['javalib/core-icu4j.jar','lib64/libicu.so','lib64/libicui18n.so','lib64/libicuuc.so',
                          'lib64/libicu_jni.so','lib64/libandroidicu.so'],
    'com.android.conscrypt': ['javalib/conscrypt.jar','lib64/libjavacrypto.so','lib64/libcrypto.so','lib64/libssl.so'],
    'com.android.tzdata': [],
}

for name in os.listdir(os.path.join(work, 'apex')):
    base = name
    for suffix in ('.capex', '.apex'):
        if base.endswith(suffix):
            base = base[:-len(suffix)]
            break
    if base not in targets:
        continue
    payload, zf = find_in_apex(os.path.join(work, 'apex', name))
    if payload is None:
        print(f'  {name}: no apex_payload.img, skipping')
        continue
    img = os.path.join(work, f'{base}-payload.img')
    open(img, 'wb').write(payload)
    dst = os.path.join(out, base)
    os.makedirs(dst, exist_ok=True)
    for rel in targets[base]:
        # 用 debugfs 从 apex_payload.img (ext4/erofs) 里抽
        target = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        dbg = shutil.which('debugfs') or '/opt/homebrew/opt/e2fsprogs/sbin/debugfs'
        r = subprocess.run([dbg, '-R', f'dump /{rel} {target}', img], capture_output=True, text=True)
        if not os.path.exists(target) or os.path.getsize(target) == 0:
            print(f'  MISS {name}!/{rel}')
        else:
            print(f'  ok   {name}/{rel} ({os.path.getsize(target)} bytes)')
    # etc (icu 数据, tzdata)
    if base == 'com.android.i18n':
        os.makedirs(os.path.join(dst, 'etc'), exist_ok=True)
        dbg = shutil.which('debugfs') or '/opt/homebrew/opt/e2fsprogs/sbin/debugfs'
        subprocess.run([dbg, '-R', f'rdump /etc/icu {os.path.join(dst, "etc")}', img], capture_output=True)
    if base == 'com.android.tzdata':
        os.makedirs(os.path.join(dst, 'etc'), exist_ok=True)
        dbg = shutil.which('debugfs') or '/opt/homebrew/opt/e2fsprogs/sbin/debugfs'
        subprocess.run([dbg, '-R', f'rdump /etc {os.path.join(dst, "etc")}', img], capture_output=True)
EOF

# org.apache.http.legacy.jar: Apache HttpClient, for apps that target API 27 or
# lower (or ask for it in their manifest). Unlike everything above it is not in
# an APEX -- it lives under /system/framework -- and build_java_runtime.sh takes
# it from a path on the build machine instead. Without it the runtime logs
# "cannot open .../org.apache.http.legacy.jar" and those apps lose their HTTP
# stack. Pull it from the same image.
echo "==> extracting org.apache.http.legacy.jar"
HTTPJAR=""
for cand in /system/framework/org.apache.http.legacy.jar \
            /system/framework/org.apache.http.legacy.boot.jar \
            /apex/com.android.art/org.apache.http.legacy.jar; do
    "$DEBUGFS" -R "dump $cand $WORK/http-legacy.jar" "$WORK/system.img" >/dev/null 2>&1 || true
    if [ -s "$WORK/http-legacy.jar" ]; then HTTPJAR="$cand"; break; fi
done
if [ -n "$HTTPJAR" ]; then
    cp "$WORK/http-legacy.jar" "$OUT/org.apache.http.legacy.jar"
    echo "    from $HTTPJAR ($(wc -c < "$OUT/org.apache.http.legacy.jar") bytes)"
else
    # 再扫一遍 framework 目录, 有些版本把它放在别处或加了后缀
    "$DEBUGFS" -R "ls -l /system/framework" "$WORK/system.img" 2>/dev/null \
        | grep -i 'http.*legacy' || true
    echo "    NOT FOUND; apps that need Apache HttpClient will lack it" >&2
fi

echo "==> result"
find "$OUT" -type f | head -60
du -sh "$OUT" || true
