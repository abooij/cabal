. ./common.sh

require_ghc_ge 708

cd T4049
cabal sandbox init > /dev/null
cabal install --enable-shared > /dev/null
$GHC -no-hs-main UseLib.c -o UseLib
echo "$GHC"
$PWD/UseLib
# $GHC -no-hs-main UseLib.c -o UseLib -lmyforeignlib -L"$PWD/.cabal-sandbox/lib"
find "$PWD/.cabal-sandbox/"
DYLD_LIBRARY_PATH="$PWD/.cabal-sandbox/lib" $PWD/UseLib
cabal exec "$PWD/UseLib"
