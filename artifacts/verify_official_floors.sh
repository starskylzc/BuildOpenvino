#!/usr/bin/env bash
# 严格验证 ORT 1.25.0 每个官方 artifact 的 OS 最低支持版本。
# 不靠 strings,不靠假设 — 直接解析 ELF (Linux) / Mach-O (macOS) / PE (Windows) 头部。
#
# Linux  .so:    ELF .gnu.version_r section,取所有依赖里 GLIBC_X.Y 的最大值 = floor
# macOS  .dylib: Mach-O LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX,minos 字段 = floor
# Windows .dll:  PE OPTIONAL_HEADER MajorOSVersion + MajorSubsystemVersion = floor
set -uo pipefail
ARTIFACTS_DIR="${1:-/tmp/ort-official}"
WORK=/tmp/ort-floor-check
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"

# ── ELF (Linux) ──
# 找文件里所有 "GLIBC_X.Y" 字符串,拿最大版本 = floor。这是 ld-linux 解析时检查的真实下限。
elf_glibc_floor() {
  local f="$1"
  LC_ALL=C grep -aoE "GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?" "$f" 2>/dev/null \
    | sort -uV | tail -1
}

# ── Mach-O (macOS) ──
# 解析 LC_BUILD_VERSION (cmd=0x32) 或 LC_VERSION_MIN_MACOSX (cmd=0x24)。
# 在 load commands 区扫描 4-byte 对齐的位置,找到这两个 cmd 字节。
machO_minos() {
  local f="$1"
  # 读 e_lfanew = mach-o header.sizeofcmds 在 offset 20 (32-bit) 或 32 (64-bit)
  # 对 mh_64,header 32 字节,sizeofcmds at offset 20
  local magic=$(xxd -l 4 -p "$f" 2>/dev/null)
  local hdr_size=32   # mh_64
  local sizeofcmds_off=20
  if [ "$magic" = "feedface" ]; then  # 32-bit MH_MAGIC
    hdr_size=28
    sizeofcmds_off=20
  fi
  local sizeofcmds_hex=$(xxd -s $sizeofcmds_off -l 4 -p "$f" 2>/dev/null)
  # little-endian 4 字节转十进制
  local sizeofcmds=$(printf '%d' "0x${sizeofcmds_hex:6:2}${sizeofcmds_hex:4:2}${sizeofcmds_hex:2:2}${sizeofcmds_hex:0:2}")
  local end=$((hdr_size + sizeofcmds))
  local off=$hdr_size
  while [ $off -lt $end ]; do
    local cmd_hex=$(xxd -s $off -l 4 -p "$f")
    case "$cmd_hex" in
      32000000)  # LC_BUILD_VERSION
        local minos_hex=$(xxd -s $((off + 12)) -l 4 -p "$f")
        # 4 字节 LE: byte0=patch, byte1=minor, byte2-3=major (LE encoded)
        local b0="0x${minos_hex:0:2}"; local b1="0x${minos_hex:2:2}"; local b2="0x${minos_hex:4:2}"; local b3="0x${minos_hex:6:2}"
        local major=$(( (b3<<8) + b2 ))
        local minor=$(printf '%d' "$b1")
        local patch=$(printf '%d' "$b0")
        echo "${major}.${minor}.${patch}"
        return
        ;;
      24000000)  # LC_VERSION_MIN_MACOSX
        local ver_hex=$(xxd -s $((off + 8)) -l 4 -p "$f")
        local b0="0x${ver_hex:0:2}"; local b1="0x${ver_hex:2:2}"; local b2="0x${ver_hex:4:2}"; local b3="0x${ver_hex:6:2}"
        local major=$(( (b3<<8) + b2 ))
        local minor=$(printf '%d' "$b1")
        local patch=$(printf '%d' "$b0")
        echo "${major}.${minor}.${patch}"
        return
        ;;
    esac
    # 跳到下一条 load command:cmdsize 在 cmd 之后 4 字节
    local cmdsize_hex=$(xxd -s $((off + 4)) -l 4 -p "$f")
    local cmdsize=$(printf '%d' "0x${cmdsize_hex:6:2}${cmdsize_hex:4:2}${cmdsize_hex:2:2}${cmdsize_hex:0:2}")
    [ $cmdsize -le 0 ] && break
    off=$((off + cmdsize))
  done
  echo "(none-found)"
}

# ── PE (Windows) ──
# e_lfanew at offset 0x3C → PE sig "PE\0\0" → IMAGE_FILE_HEADER (20B) → IMAGE_OPTIONAL_HEADER。
# Optional header 内 OS Version 在 offset 40 (PE32+) / 40 (PE32 也是同样位置因为已经过 ImageBase)。
# 等等,我得仔细看:
#   PE32:  Magic(2) Linker(2) SizeOfCode(4) SizeOfInitData(4) SizeOfUninitData(4) EntryPoint(4) BaseOfCode(4) BaseOfData(4) ImageBase(4) SectAlign(4) FileAlign(4) MajorOS(2) ...
#   PE32+: 同上但去掉 BaseOfData(4),ImageBase(8)
#   PE32+ size to MajorOS = 2+2+4+4+4+4+4+8+4+4 = 40
#   PE32  size to MajorOS = 2+2+4+4+4+4+4+4+4+4+4 = 40 也是
# 所以 MajorOS 都在 optional header offset 40 处。
# MajorSubsystem 在 OS+8 = 48。
pe_min_os() {
  local f="$1"
  # e_lfanew at 0x3C (4 bytes LE)
  local ef_hex=$(xxd -s 60 -l 4 -p "$f" 2>/dev/null)
  local e_lfanew=$(printf '%d' "0x${ef_hex:6:2}${ef_hex:4:2}${ef_hex:2:2}${ef_hex:0:2}")
  # PE sig at e_lfanew should be "PE\0\0" (50 45 00 00)
  local sig=$(xxd -s $e_lfanew -l 4 -p "$f")
  if [ "$sig" != "50450000" ]; then
    echo "(not-PE: sig=$sig)"
    return
  fi
  # OPTIONAL_HEADER starts at e_lfanew + 4 (PE sig) + 20 (FILE_HEADER)
  local opt_off=$((e_lfanew + 24))
  local magic_hex=$(xxd -s $opt_off -l 2 -p "$f")
  # 0b01 = PE32, 0b02 = PE32+
  local pe_kind="PE32+"
  if [ "$magic_hex" = "0b01" ]; then pe_kind="PE32"; fi
  # MajorOS at opt+40, MinorOS at opt+42, MajorSubsystem at opt+48, MinorSubsystem at opt+50
  local mos_hex=$(xxd -s $((opt_off + 40)) -l 2 -p "$f")
  local mios_hex=$(xxd -s $((opt_off + 42)) -l 2 -p "$f")
  local msub_hex=$(xxd -s $((opt_off + 48)) -l 2 -p "$f")
  local misub_hex=$(xxd -s $((opt_off + 50)) -l 2 -p "$f")
  local mos=$(printf '%d' "0x${mos_hex:2:2}${mos_hex:0:2}")
  local mios=$(printf '%d' "0x${mios_hex:2:2}${mios_hex:0:2}")
  local msub=$(printf '%d' "0x${msub_hex:2:2}${msub_hex:0:2}")
  local misub=$(printf '%d' "0x${misub_hex:2:2}${misub_hex:0:2}")
  echo "${pe_kind} OS=${mos}.${mios} Subsys=${msub}.${misub}"
}

# ── 处理每个 artifact ──
echo "=== 解析所有官方 ORT 1.25.0 artifact 的 OS 最低支持版本 ==="
echo ""

for tgz in "$ARTIFACTS_DIR"/onnxruntime-linux-*.tgz; do
  name=$(basename "$tgz" .tgz)
  echo "── $name ──"
  rm -rf extract && mkdir -p extract
  tar xzf "$tgz" -C extract 2>/dev/null
  for so in $(find extract -name "libonnxruntime.so.1.25.0" -o -name "libonnxruntime_providers_*.so" | sort); do
    floor=$(elf_glibc_floor "$so")
    short=$(basename "$so")
    printf "  %-50s GLIBC floor: %s\n" "$short" "$floor"
  done
  echo ""
done

for tgz in "$ARTIFACTS_DIR"/onnxruntime-osx-*.tgz; do
  name=$(basename "$tgz" .tgz)
  echo "── $name ──"
  rm -rf extract && mkdir -p extract
  tar xzf "$tgz" -C extract 2>/dev/null
  for dylib in $(find extract -name "*.dylib" | sort | head -3); do
    minos=$(machO_minos "$dylib")
    short=$(basename "$dylib")
    printf "  %-50s macOS min: %s\n" "$short" "$minos"
  done
  echo ""
done

for zip in "$ARTIFACTS_DIR"/onnxruntime-win-*.zip; do
  name=$(basename "$zip" .zip)
  echo "── $name ──"
  rm -rf extract && mkdir -p extract
  unzip -q "$zip" -d extract 2>/dev/null
  for dll in $(find extract -name "onnxruntime.dll" -o -name "DirectML.dll" -o -name "onnxruntime_providers_*.dll" | sort | head -5); do
    info=$(pe_min_os "$dll")
    short=$(basename "$dll")
    printf "  %-50s %s\n" "$short" "$info"
  done
  echo ""
done

echo "=== 注解 ==="
echo "  Linux GLIBC floor 对应:"
echo "    2.27 = Ubuntu 18.04 / 中标麒麟 V7"
echo "    2.28 = Debian 10 / RHEL 8 / 麒麟 V10 / UOS V20"
echo "    2.31 = Ubuntu 20.04"
echo "    2.34 = Ubuntu 22.04 / Fedora 35"
echo "  macOS min 对应:"
echo "    10.15 Catalina (2019)  11.0 Big Sur (2020)  12.0 Monterey (2021)"
echo "    13.0 Ventura (2022)    14.0 Sonoma (2023)   15.0 Sequoia (2024)"
echo "  Windows Subsystem version 对应:"
echo "    6.0 Vista / Server 2008  6.1 Win7  6.2 Win8  6.3 Win8.1"
echo "    10.0 = Win10/11 (大多数现代 PE 都标 10.0,实际兼容性靠 SDK + API 调用)"
