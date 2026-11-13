#!/bin/zsh
# Render the corpus pages (quartets: first 3 pages) and read each with ScannerCheck --copista, one at a time.
# usage: tools/eval/run.sh WORKDIR OUTNAME     then: python3 tools/eval/score.py WORKDIR/corpus WORKDIR/OUTNAME
set -e
REPO=${0:A:h:h:h}; W=$1; OUT=$W/$2
swift build -c release --package-path $REPO --product ScannerCheck >/dev/null
BIN=$REPO/.build/release/ScannerCheck; MODELS=$REPO/Sources/ScannerCore/Resources/Models
if [ ! -d $W/corpus/pages ]; then
  swiftc -O $REPO/tools/eval/render.swift -o $W/render
  mkdir -p $W/corpus/pages
  for f in $W/corpus/pdf/*.pdf; do case ${f:t} in St_*) m=3;; *) m=99;; esac; $W/render $f $W/corpus/pages $m; done
fi
mkdir -p $OUT
for p in $W/corpus/pages/*.png; do n=${p:t:r}; $BIN --copista $p $MODELS $OUT/$n > $OUT/$n.log 2>&1 || echo "FAIL $n"; done
