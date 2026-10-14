#!/bin/bash
# Checks DigUp's Windows installer the way someone first meets it: installed silently for the current user, a hidden
# first launch goes through setup by itself (the model from MODELS, downloaded there when it isn't), indexes a picture,
# a screenshot (named "Screenshot …", so the helper's OCR path runs), a recording and a note with the model and finds the
# note from the search panel; then its helper runs with only Windows on PATH (everything else it needs is beside it), and
# digup-ocr runs on its own. In Git for Windows' bash; the packages workflow
# runs it after building the installer.
#   MODELS=<folder> scripts/check-windows-package.sh <DigUp_x.y.z_<arch>-setup.exe>
set -euo pipefail
cd "$(dirname "$0")/.."
setup=${1:?the installer}
models=${MODELS:?set MODELS to a folder for the model files (they are downloaded there when missing)}
mkdir -p "$models"
models=$(cygpath -m "$models")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
win() { cygpath -m "$1"; }

echo "installing $setup"
MSYS_NO_PATHCONV=1 "$setup" /S
installed=$(cygpath -u "$LOCALAPPDATA")/DigUp
ls "$installed/DigUp.exe" "$installed/helper/digup.exe" "$installed/helper/digup-ocr.exe" > /dev/null
# The licenses of what the installer carries, beside the app.
grep -q "GNU LESSER GENERAL PUBLIC LICENSE" "$installed/THIRD-PARTY-NOTICES.txt" || { echo "no license notices"; exit 1; }

mkdir -p "$work/files"
cp Tests/LlamaRuntimeTests/Reference/photo.jpg Tests/LlamaRuntimeTests/Reference/speech.wav docs/logo.png "$work/files/"
# Screenshots are recognized by their file name's prefix (Rules.swift).
cp Tests/LlamaRuntimeTests/Reference/screen.png "$work/files/Screenshot screen.png"
cat > "$work/files/recipe.txt" <<'TEXT'
Lemon cake

Cream the butter and sugar, beat in three eggs, then fold in the flour, the zest of two lemons and a splash of milk.
Bake for forty minutes at 180 degrees and pour the lemon syrup over it while it is still warm.
TEXT

echo "first launch"
started=$(date +%s)
"$installed/DigUp.exe" --index "$(win "$work/index")" --models "$models" --settings "$(win "$work/settings.json")" \
  --offer "$(win "$work/files")" --hotkey "Ctrl+Alt+Shift+D" --debug-setup --debug-query "how long to bake the cake" \
  --debug-quit > "$work/out.txt" 2> "$work/err.txt" &
app=$!
report=
while kill -0 "$app" 2> /dev/null && (( $(date +%s) - started < 1800 )); do
  report=$(grep '^{' "$work/out.txt" 2> /dev/null | tail -1 || true)
  [[ -n $report ]] && break
  sleep 2
done
# The report comes just before DigUp quits; a DigUp still there a minute later is ended (a session without a desktop,
# as a service has, keeps it from quitting).
for _ in $(seq 30); do kill -0 "$app" 2> /dev/null || break; sleep 2; done
if kill -0 "$app" 2> /dev/null; then
  echo "DigUp didn't quit after its report: ending it"
  taskkill //F //T //IM DigUp.exe > /dev/null || true
fi
report=$(grep '^{' "$work/out.txt" | tail -1 || true)
echo "after $(( $(date +%s) - started )) s"
if [[ -z $report ]]; then
  echo "--- stdout"; tail -20 "$work/out.txt"
  echo "--- stderr"; tail -40 "$work/err.txt"
  echo "no report from the panel"
  exit 1
fi
echo "panel: $report"
if [[ $report != *'"recipe.txt"'* ]]; then
  echo "the panel didn't find recipe.txt"
  exit 1
fi

echo "the helper with only Windows on PATH"
helper=$installed/helper/digup.exe
PATH="/c/Windows/System32:/c/Windows:/c/Windows/System32/Wbem" "$helper" status --index "$(win "$work/index")" \
  | tee "$work/status.txt"
grep -Eq '^vectors: 5 in [56] segments' "$work/status.txt" || { echo "not every file has a vector"; exit 1; }
PATH="/c/Windows/System32:/c/Windows:/c/Windows/System32/Wbem" DIGUP_MODELS="$models" \
  "$helper" search "how long to bake the cake" --index "$(win "$work/index")" -n 3

# The OCR program reads the screenshot with Windows' OCR. Exit 2 means no OCR language is installed (the CI runner may
# have none): that is noted, not a failure. Exit 1 or anything else is. (The reference screenshot is drawn bars, not
# letters, so empty output is fine; this checks the program runs, not what it reads.)
echo "the OCR program"
ocr=$installed/helper/digup-ocr.exe
check_code=0
"$ocr" --check > /dev/null 2> "$work/ocr-err.txt" || check_code=$?
case $check_code in
  0) echo "digup-ocr --check: an OCR engine is available" ;;
  2) echo "note: no OCR language is installed here" ;;
  *) echo "digup-ocr --check exited $check_code"; cat "$work/ocr-err.txt"; exit 1 ;;
esac
ocr_code=0
"$ocr" "$(win "$work/files/Screenshot screen.png")" > "$work/ocr.txt" 2> "$work/ocr-err.txt" || ocr_code=$?
case $ocr_code in
  0) echo "digup-ocr read the screenshot ($(wc -c < "$work/ocr.txt") bytes of text)" ;;
  2) echo "note: no OCR language is installed here, so digup-ocr was not checked" ;;
  *) echo "digup-ocr exited $ocr_code"; cat "$work/ocr-err.txt"; exit 1 ;;
esac
[[ $check_code == "$ocr_code" ]] || { echo "digup-ocr --check ($check_code) and the image run ($ocr_code) disagree"; exit 1; }

# With a language, a screenshot with words in it: digup-ocr reads the invoice number, and the helper indexes the
# screenshot and finds it by that number (an exact word that only OCR could have given it).
if [[ $check_code == 0 ]]; then
  echo "OCR, end to end"
  mkdir -p "$work/ocr-files"
  cp Tests/DigUpKitTests/Pictures/ocr-invoice.png "$work/ocr-files/Screenshot invoice.png"
  "$ocr" "$(win "$work/ocr-files/Screenshot invoice.png")" | tee "$work/ocr-invoice.txt"
  grep -q 48213 "$work/ocr-invoice.txt" || { echo "digup-ocr didn't read the invoice number"; exit 1; }
  PATH="/c/Windows/System32:/c/Windows:/c/Windows/System32/Wbem" DIGUP_MODELS="$models" \
    "$helper" index "$(win "$work/ocr-files")" --index "$(win "$work/ocr-index")" > /dev/null
  PATH="/c/Windows/System32:/c/Windows:/c/Windows/System32/Wbem" DIGUP_MODELS="$models" \
    "$helper" search 48213 --index "$(win "$work/ocr-index")" -n 3 | tee "$work/ocr-search.txt"
  grep -Eq '^ *1\..*Screenshot invoice\.png' "$work/ocr-search.txt" || { echo "searching 48213 didn't rank the screenshot first"; exit 1; }

  # A second language: the runner has Russian OCR and ru-RU in the user's languages (the workflow's step before this),
  # so digup-ocr reads with both engines and keeps the one whose script fits. The file name is not ASCII, which
  # exercises non-ASCII paths. (ё is left out of the assertions: OCR may give е.)
  echo "OCR in a second language"
  cp Tests/DigUpKitTests/Pictures/ocr-russian.png "$work/ocr-files/Screenshot счёт.png"
  "$ocr" "$(win "$work/ocr-files/Screenshot счёт.png")" | tee "$work/ocr-russian.txt"
  grep -q 73591 "$work/ocr-russian.txt" || { echo "digup-ocr didn't read the Russian invoice number"; exit 1; }
  grep -q "оплачен" "$work/ocr-russian.txt" || { echo "digup-ocr didn't read the Russian word (is Russian OCR installed?)"; exit 1; }
  "$ocr" "$(win "$work/ocr-files/Screenshot invoice.png")" > "$work/ocr-invoice.txt"
  grep -q 48213 "$work/ocr-invoice.txt" || { echo "with two languages, digup-ocr didn't read the English invoice"; exit 1; }

  # A scan: a PDF whose only page is a picture of text, read with OCR when it is indexed.
  cp Tests/DigUpKitTests/Pictures/ocr-scan.pdf "$work/ocr-files/lease scan.pdf"
  PATH="/c/Windows/System32:/c/Windows:/c/Windows/System32/Wbem" DIGUP_MODELS="$models" \
    "$helper" index "$(win "$work/ocr-files")" --index "$(win "$work/ocr-index")" > /dev/null
  for found in "73591:Screenshot счёт.png" "48213:Screenshot invoice.png" "61844:lease scan.pdf"; do
    PATH="/c/Windows/System32:/c/Windows:/c/Windows/System32/Wbem" DIGUP_MODELS="$models" \
      "$helper" search "${found%%:*}" --index "$(win "$work/ocr-index")" -n 3 | tee "$work/ocr-search.txt"
    grep -E '^ *1\.' "$work/ocr-search.txt" | grep -qF "${found#*:}" \
      || { echo "searching ${found%%:*} didn't rank ${found#*:} first"; exit 1; }
  done
fi
echo "ok"
