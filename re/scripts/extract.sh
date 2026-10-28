#!/bin/sh
# Unpacks the Escargot WLM 8.1 installer into OUT/{msi,core,targets}.
# usage: re/scripts/extract.sh path/to/escargot-wlm-8.1.0178-en.msi OUT
set -eu
MSI="$1"; OUT="$2"
mkdir -p "$OUT/msi" "$OUT/core" "$OUT/targets"
7zz x -y -o"$OUT/msi" "$MSI" >/dev/null
7zz x -y -o"$OUT/core" "$OUT/msi/MsgrCore.cab" >/dev/null
cp "$OUT/core/msnmsgrexe" "$OUT/targets/msnmsgr.exe"
cp "$OUT/core/escargotdll" "$OUT/targets/escargot.dll"
cp "$OUT/core/abssmdll" "$OUT/targets/abssm.dll"
cp "$OUT/core/msgscdll" "$OUT/targets/msgsc.dll"
cp "$OUT/core/msncoredll" "$OUT/targets/msncore.dll"
cp "$OUT/core/SDKCOMPONENTS_PPCRL_MSIDCRL40.DLL."* "$OUT/targets/msidcrl40.dll"
echo "targets in $OUT/targets"
