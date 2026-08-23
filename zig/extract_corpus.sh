#!/bin/sh
# extract_corpus.sh — transcribe every buildfile heredoc from tests/build.sh
# into zig/tests/corpus/cNNN_<name>.dhall (unique counter prefix avoids the
# same-filename overwrites that happen across cases). Run from zig/.
set -eu
cd "$(dirname "$0")/.."
mkdir -p zig/tests/corpus
rm -f zig/tests/corpus/*.dhall

awk '
BEGIN { n=0 }
/^cat > .*\.dhall *<<.*BUILDEOF/ {
    line=$0
    sub(/^cat > /,"",line)
    sub(/ *<<.*/,"",line)
    fname=line
    n++
    gsub(/\//,"_",fname)
    out="zig/tests/corpus/c" sprintf("%03d",n) "_" fname
    infile=1
    next
}
infile && /^BUILDEOF$/ { infile=0; next }
infile { print > out }
' tests/build.sh

echo "extracted $(ls zig/tests/corpus/*.dhall | wc -l) corpus files"
