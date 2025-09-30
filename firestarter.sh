#!/usr/bin/env bash
set -u -o pipefail

# ===== Colors/Log =====
NC="\033[0m"; RED="\033[1;31m"; YEL="\033[1;33m"; GRN="\033[1;32m"; CYA="\033[1;36m"; MAG="\033[1;35m"; BLU="\033[1;34m"
info(){ echo -e "${CYA}[INFO]${NC} $*"; }
warn(){ echo -e "${YEL}[WARN]${NC} $*"; }
err (){ echo -e "${RED}[ERROR]${NC} $*"; }
ok  (){ echo -e "${GRN}[OK]${NC} $*"; }
note(){ echo -e "${MAG}[NOTE]${NC} $*"; }

# ===== Tunables =====
RETRY_PAUSE=8; MAX_RETRIES=3
SOL_WAIT_SECS=10; MAX_SOL_CHECKS=18
AVAIL_WAIT_SECS=10; MAX_AVAIL_CHECKS=30
POST_AVAIL_SLEEP=12   # grace pause after object becomes "available"

WORKDIR="/root/pipe/test-downloads"
PASS_DIR="/root/pipe"
PASS_LOG="${PASS_DIR}/passwords.log"
CONFIG_FILE="$HOME/.pipe-cli.json"
STATE_DIR="$HOME/.pipe-script"
STATE_USERNAME_FILE="$STATE_DIR/username.txt"

umask 077
mkdir -p "$WORKDIR" /tmp/firestarter
touch "$PASS_LOG"

# ===== Helpers =====
retry_run(){ local d="$1"; shift; local a=1; while :; do info "$d (attempt $a/$MAX_RETRIES)"; if eval "$@"; then ok "$d succeeded."; return 0; fi; ((a>=MAX_RETRIES))&&{ err "$d failed after $MAX_RETRIES attempts."; return 1; }; warn "$d failed. Retrying after ${RETRY_PAUSE}s…"; sleep "$RETRY_PAUSE"; a=$((a+1)); done; }
retry_capture(){ local d="$1" v="$2"; shift 2; local a=1 out rc; while :; do info "$d (attempt $a/$MAX_RETRIES)"; out="$(eval "$@" 2>&1)"; rc=$?; if [[ $rc -eq 0 ]]; then ok "$d succeeded."; printf -v "$v" "%s" "$out"; return 0; fi; ((a>=MAX_RETRIES))&&{ err "$d failed after $MAX_RETRIES attempts."; printf -v "$v" ""; return 1; }; warn "$d failed. Retrying after ${RETRY_PAUSE}s…"; sleep "$RETRY_PAUSE"; a=$((a+1)); done; }
gen_username(){ tr -dc 'a-z' </dev/urandom | head -c 8; }
gen_password(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12; }
rand_suffix(){ tr -dc 'a-z0-9' </dev/urandom | head -c 6; }
rand_int_range(){ awk -v min="$1" -v max="$2" 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'; }
rand_sol_amount(){ n=$(rand_int_range 70 90); awk -v n="$n" 'BEGIN{printf("%.2f", n/100)}'; }

parse_sol_balance(){ awk '/^[[:space:]]*SOL:/{print $2; exit} /^[[:space:]]*Lamports:/{printf "%.9f\n",$2/1e9; exit}' | head -n1; }
parse_pubkey(){ awk '{l=tolower($0)} l~/^[[:space:]]*pubkey:/{print $2; exit}'; }
parse_next_line_after(){ awk -v pat="$1" 'BEGIN{f=0} index($0, pat){f=1; next} f && $0 !~ /^[[:space:]]*$/ {gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit}' | head -n1; }
parse_social_link(){ parse_next_line_after "Social media link"; }
parse_direct_link(){ parse_next_line_after "Direct link"; }

get_user_id_from_config(){ [[ -f "$CONFIG_FILE" ]] || return 1; sed -n 's/.*"user_id"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/p' "$CONFIG_FILE" | head -n1; }
recover_username(){
  [[ -s "$STATE_USERNAME_FILE" ]] && { cat "$STATE_USERNAME_FILE"; return; }
  local out code uid prefix
  out="$(pipe referral show 2>/dev/null || true)"
  code="$(printf "%s" "$out" | sed -n 's/.*\b\([a-z]\{3,\}\)-[A-Za-z0-9]\{4,\}\b.*/\1/p' | head -n1)"
  [[ -n "$code" ]] && { echo "$code" | tee "$STATE_USERNAME_FILE"; return; }
  uid="$(get_user_id_from_config || true)"
  if [[ -n "$uid" ]]; then prefix="$(echo "$uid"|tr -d '-'|cut -c1-8)"; echo "pipeuser-${prefix}" | tee "$STATE_USERNAME_FILE"; return; fi
  gen_username | tee "$STATE_USERNAME_FILE"
}

has_encrypt_password_flag(){ pipe upload-file --help 2>/dev/null | grep -q -- '--password'; }
has_decrypt_password_flag(){ pipe download-file --help 2>/dev/null | grep -q -- '--password'; }
remote_exists(){ pipe file-info "$1" >/dev/null 2>&1; }

wait_until_available(){
  local name="$1" i=1; info "Waiting availability of '$name' (up to $((MAX_AVAIL_CHECKS*AVAIL_WAIT_SECS))s)…"
  while (( i<=MAX_AVAIL_CHECKS )); do
    if pipe file-info "$name" >/dev/null 2>&1; then ok "'$name' is available."; return 0; fi
    sleep "$AVAIL_WAIT_SECS"; ((i++))
  done
  err "'$name' still not available after waiting."; return 1
}

add_preview_param() {
  local u="$1"
  [[ -z "$u" ]] && { echo ""; return; }
  if [[ "$u" == *\?* ]]; then
    echo "${u}&preview=true"
  else
    echo "${u}?preview=true"
  fi
}

# ========================= File selection helper =========================
choose_source_files(){
  local choice prompt_dir list_dir files tmp sel indices idx file
  echo
  echo -e "${CYA}Source file selection:${NC}"
  echo "  (G)enerate random file (original behavior)"
  echo "  (C)hoose existing file(s) from a directory (you can pick multiple)"
  echo "  (P)aste full path to file"
  read -rp "$(echo -e "${CYA}[INPUT]${NC} Select option [G/C/P] (Enter=G): ")" choice
  choice="${choice:-G}"
  case "${choice^^}" in
    G) SOURCE_CHOICE="generate"; SRC_FILES=(); return 0 ;;
    C)
      read -rp "$(echo -e "${CYA}[INPUT]${NC} Directory to browse (Enter for /tmp/firestarter): ")" list_dir
      list_dir="${list_dir:-/tmp/firestarter}"
      [[ -d "$list_dir" ]] || { err "Directory '$list_dir' not found."; return 1; }
      echo "Listing regular files in $list_dir (largest first):"
      mapfile -t files < <(find "$list_dir" -maxdepth 1 -type f -printf "%s\t%p\n" 2>/dev/null | sort -nr | awk -F'\t' '{printf "%s\t%s\n",$1,$2}' | nl -v1 -w3 -s'. ' | sed 's/^\s*//')
      [[ ${#files[@]} -gt 0 ]] || { warn "No regular files found in $list_dir"; return 1; }
      for entry in "${files[@]}"; do
        raw="$(echo "$entry" | sed -E 's/^[[:space:]]*([0-9]+)\.\s*([0-9]+)\t(.*)/\1\t\2\t\3/')"
        idx="$(printf "%s" "$raw" | cut -f1)"
        size="$(printf "%s" "$raw" | cut -f2)"
        path="$(printf "%s" "$raw" | cut -f3-)"
        printf "%3s) %10s bytes    %s\n" "$idx" "$size" "$path"
      done
      echo
      read -rp "$(echo -e "${CYA}[INPUT]${NC} Enter indices to select (e.g. 1 3 4) or range (1-3), comma-separated: ")" sel
      sel="${sel//,/ }"
      SRC_FILES=()
      for token in $sel; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
          a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
          for ((k=a;k<=b;k++)); do
            entry="${files[k-1]}"
            path="$(printf "%s" "$entry" | sed -E 's/^[[:space:]]*[0-9]+\.\s*[0-9]+\t//')"
            SRC_FILES+=("$path")
          done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
          entry="${files[token-1]}"
          path="$(printf "%s" "$entry" | sed -E 's/^[[:space:]]*[0-9]+\.\s*[0-9]+\t//')"
          SRC_FILES+=("$path")
        else
          warn "Skipping unrecognized token: $token"
        fi
      done
      [[ ${#SRC_FILES[@]} -gt 0 ]] || { err "No files selected."; return 1; }
      SOURCE_CHOICE="existing"; return 0
      ;;
    P)
      read -rp "$(echo -e "${CYA}[INPUT]${NC} Paste full path to file: ")" file
      [[ -f "$file" ]] || { err "File '$file' not found."; return 1; }
      SRC_FILES=("$file"); SOURCE_CHOICE="existing"; return 0
      ;;
    *) err "Unknown choice '$choice'"; return 1 ;;
  esac
}

# ========================= Pre-flight =========================
command -v pipe >/dev/null 2>&1 || { err "CLI 'pipe' not found"; exit 1; }
mkdir -p "$WORKDIR"

# ========================= User ===============================
USERNAME=""
if [[ -f "$CONFIG_FILE" ]] && grep -q '"user_id"' "$CONFIG_FILE"; then
  ok "Existing Pipe user config detected: $CONFIG_FILE"
  USERNAME="$(recover_username)"
else
  USERNAME="$(gen_username)"
  retry_run "Create user" "pipe new-user ${USERNAME}" || { err "Cannot proceed without user."; exit 1; }
  echo "$USERNAME" > "$STATE_USERNAME_FILE"
fi

# Pubkey (best-effort)
SOL_CHECK_OUT="$(pipe check-sol 2>/dev/null || true)"
SOL_PUBKEY="$(printf "%s" "$SOL_CHECK_OUT" | parse_pubkey || true)"
[[ -n "$SOL_PUBKEY" ]] && ok "Solana Pubkey: ${SOL_PUBKEY}" || warn "Could not parse Solana Pubkey."

# ========================= Faucet prompt ======================
note "ACTION REQUIRED: Request DevNet SOL, then press Enter."
echo -e "${BLU}Faucets:${NC} https://faucet.solana.com  or  https://solfate.com/faucet"
[[ -n "$SOL_PUBKEY" ]] && echo -e "${BLU}Your Pubkey:${NC} ${SOL_PUBKEY}"
read -rp "$(echo -e "${CYA}[INPUT]${NC} Press Enter after requesting DevNet SOL…")" _

# ========================= Source file(s) selection ===========
shopt -s nullglob

# Ask for folder; Enter = default
read -rp "$(echo -e "${CYA}[INPUT]${NC} Directory to browse (Enter for /tmp/firestarter): ")" FOLDER
FOLDER="${FOLDER:-/tmp/firestarter}"

if [[ ! -d "$FOLDER" ]]; then
  err "Directory '$FOLDER' not found."
  exit 1
fi

FILES=("$FOLDER"/*)
if [[ ${#FILES[@]} -eq 0 ]]; then
  err "No files found in $FOLDER"
  exit 1
fi

echo -e "\nAvailable files in ${FOLDER}:"
for i in "${!FILES[@]}"; do
  printf "  %d) %s\n" $((i+1)) "$(basename "${FILES[i]}")"
done

read -rp "$(echo -e "${CYA}[INPUT]${NC} Enter indices (e.g. 1 3 5, 2-4): ")" sel

expand_selection() {
  local input="$1" result=()
  for token in $(echo "$input" | tr ',' ' '); do
    if [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
      local start="${token%-*}" end="${token#*-}"
      for ((j=start; j<=end; j++)); do result+=("$j"); done
    else
      result+=("$token")
    fi
  done
  echo "${result[@]}"
}

SELECTED_IDX=($(expand_selection "$sel"))

SELECTED_FILES=()
for idx in "${SELECTED_IDX[@]}"; do
  if (( idx >= 1 && idx <= ${#FILES[@]} )); then
    SELECTED_FILES+=("${FILES[idx-1]}")
  else
    warn "Index $idx is out of range"
  fi
done

if [[ ${#SELECTED_FILES[@]} -eq 0 ]]; then
  err "No valid files selected."
  exit 1
fi

echo -e "${GRN}[OK]${NC} Selected files:"
printf '  %s\n' "${SELECTED_FILES[@]}"

# Make the rest of the script see these
SRC_FILES=("${SELECTED_FILES[@]}")

# For backward compatibility
SRC_FILE="${SELECTED_FILES[0]}"
BASE_NAME="$(basename "$SRC_FILE")"


# ========================= Wait for SOL =======================
SOL_BAL="0"; attempt=1
while (( attempt<=MAX_SOL_CHECKS )); do
  SOL_CHECK_OUT="$(pipe check-sol 2>/dev/null || true)"
  SOL_BAL="$(printf "%s" "$SOL_CHECK_OUT" | parse_sol_balance || echo 0)"
  info "SOL balance check #$attempt: ${SOL_BAL}"
  awk -v v="$SOL_BAL" 'BEGIN{exit !(v+0>0.0000001)}' && { ok "SOL balance is positive."; break; }
  info "No SOL yet. Sleeping ${SOL_WAIT_SECS}s…"; sleep "$SOL_WAIT_SECS"; ((attempt++))
done
(( attempt>MAX_SOL_CHECKS )) && warn "No SOL detected after waiting. Swap may fail."

# ========================= Swap SOL->PIPE (0.70–0.90) =========
SWAP_AMT="$(rand_sol_amount)"; attempt=1; SWAP_OK=0
while (( attempt<=MAX_RETRIES )); do
  info "Swap attempt ${attempt}/${MAX_RETRIES} for ${SWAP_AMT} SOL…"
  if pipe swap-sol-for-pipe "${SWAP_AMT}"; then ok "Swap succeeded."; SWAP_OK=1; break; fi
  warn "Swap failed. Decreasing amount and retrying after ${RETRY_PAUSE}s…"
  sleep "$RETRY_PAUSE"; SWAP_AMT=$(awk -v a="$SWAP_AMT" 'BEGIN{a=a-0.02; if(a<0.70)a=0.70; printf("%.2f", a)}'); ((attempt++))
done
(( SWAP_OK==0 )) && warn "Swap failed; continuing."

# ========================= Upload unencrypted (per-file) =========
has_encrypt_flag=$(has_encrypt_password_flag || true)
declare -a REMOTE_PLAINS
i=0
for src in "${SRC_FILES[@]}"; do
  ((i++))
  base="$(basename "$src")"
  REMOTE_BASENAME="my-file-${i}-${base%%.*}"
  REMOTE_PLAIN="$REMOTE_BASENAME"
if remote_exists "$REMOTE_PLAIN"; then
  note "Remote '$REMOTE_PLAIN' exists; creating a new name."
  ext="${REMOTE_PLAIN##*.}"           # file extension (e.g. mp3)
  name="${REMOTE_PLAIN%.*}"           # base name without extension
  prefix="$(tr -dc 'a-z' </dev/urandom | head -c 3)"  # random 3 letters
  REMOTE_PLAIN="${prefix}-${name}.${ext}"
fi
  retry_run "Upload unencrypted file '${src}'" "pipe upload-file \"${src}\" \"${REMOTE_PLAIN}\" --tier normal"
  REMOTE_PLAINS+=("$REMOTE_PLAIN")
done

# Wait and download each (attempt standard then legacy)
sleep "$POST_AVAIL_SLEEP"
for idx in "${!REMOTE_PLAINS[@]}"; do
  REM="${REMOTE_PLAINS[$idx]}"
  wait_until_available "$REM" || warn "Proceeding despite not-ready state for $REM."
  DST_FILE="${WORKDIR}/${REM}.dl"
  download_std(){ pipe download-file "$REM" "$DST_FILE"; }
  download_legacy(){ pipe download-file "$REM" "$DST_FILE" --legacy; }
  if ! retry_run "Download unencrypted file '$REM'" "download_std"; then
    warn "Standard download failed; trying legacy after short wait…"
    sleep "$RETRY_PAUSE"
    retry_run "Download unencrypted file '$REM' (legacy)" "download_legacy" || warn "Both streaming and legacy download failed for $REM. Skipping."
  fi
done

# ========================= Public links (robust) ========================
declare -A PUBLIC_LINKS
# (optional but safe under 'set -u'): pre-fill to N/A so lookups never explode
for REM in "${REMOTE_PLAINS[@]}"; do
  PUBLIC_LINKS["$REM"]="N/A"
done

for REM in "${REMOTE_PLAINS[@]}"; do
  wait_until_available "$REM" || warn "Proceeding despite not-ready state for $REM."
  PUBLINK_OUT=""
  if retry_capture "Create public link for ${REM}" PUBLINK_OUT "pipe create-public-link $(printf %q "$REM")"; then
    # First try: extract any URL
    EXTRACTED_URL="$(printf '%s\n' "$PUBLINK_OUT" | grep -Eo 'https?://[^[:space:]]+' | head -n1 || true)"
    if [[ -n "$EXTRACTED_URL" ]]; then
      EXTRACTED_URL="$(add_preview_param "$EXTRACTED_URL")"
      ok "Public link for ${REM}: ${EXTRACTED_URL}"
      PUBLIC_LINKS["$REM"]="$EXTRACTED_URL"
      continue
    fi

    # Fallback to label-based lines
    SOCIAL_LINK="$(printf '%s\n' "$PUBLINK_OUT" | awk '/Social media link/{getline; print; exit}')"
    DIRECT_LINK="$(printf '%s\n' "$PUBLINK_OUT" | awk '/Direct link/{getline; print; exit}')"
    if [[ -n "$SOCIAL_LINK" ]]; then
      SOCIAL_LINK="$(add_preview_param "$SOCIAL_LINK")"
      ok "Parsed Social link for ${REM}: $SOCIAL_LINK"
      PUBLIC_LINKS["$REM"]="$SOCIAL_LINK"
    elif [[ -n "$DIRECT_LINK" ]]; then
      DIRECT_LINK="$(add_preview_param "$DIRECT_LINK")"
      ok "Parsed Direct link for ${REM}: $DIRECT_LINK"
      PUBLIC_LINKS["$REM"]="$DIRECT_LINK"
    else
      warn "No URL found for ${REM}. Raw output below:"
      printf '%s\n' "$PUBLINK_OUT"
      PUBLIC_LINKS["$REM"]="N/A"
    fi
  else
    warn "create-public-link failed for ${REM}. Raw output:"
    printf '%s\n' "$PUBLINK_OUT"
    PUBLIC_LINKS["$REM"]="N/A"
  fi
done

echo -e "\n${GRN}==== PUBLIC LINKS ====${NC}"
# Use safe lookups under 'set -u'
for REM in "${REMOTE_PLAINS[@]}"; do
  printf "  %s -> %s\n" "$REM" "${PUBLIC_LINKS[$REM]-N/A}"
done

FIRST_OK_LINK="$(
  for REM in "${REMOTE_PLAINS[@]}"; do
    val="${PUBLIC_LINKS[$REM]-}"
    if [[ -n "$val" && "$val" != "N/A" ]]; then
      echo "$val"
      break
    fi
  done
)"
SOCIAL_LINK="${FIRST_OK_LINK:-N/A}"

# ========================= Encrypted upload (auto-pass) per file =======
declare -a SEC_REMOTES
for src in "${SRC_FILES[@]}"; do
  base="$(basename "$src")"
  SEC_REMOTE="secure-${base%%.*}-$(rand_suffix)"
  ENC_PASS_FILE="${PASS_DIR}/${SEC_REMOTE}.pass"
  ENC_PASS="$(gen_password)"
  echo -e "${YEL}[WARNING]${NC} Generated encryption password for ${SEC_REMOTE} (copy it now): ${BLU}${ENC_PASS}${NC}"
  if has_encrypt_password_flag; then
    retry_run "Upload encrypted file '${src}' as ${SEC_REMOTE}" "pipe upload-file \"${src}\" \"${SEC_REMOTE}\" --encrypt --password \"${ENC_PASS}\""
  else
    retry_run "Upload encrypted file '${src}' as ${SEC_REMOTE}" "{ printf '%s\n%s\n' \"${ENC_PASS}\" \"${ENC_PASS}\"; } | pipe upload-file \"${src}\" \"${SEC_REMOTE}\" --encrypt"
  fi
  printf "%s" "$ENC_PASS" > "$ENC_PASS_FILE"; chmod 600 "$ENC_PASS_FILE"
  echo "$(date -Is) ${SEC_REMOTE} ${ENC_PASS}" >> "$PASS_LOG"
  note "Password saved: ${ENC_PASS_FILE} (logged in ${PASS_LOG})"
  SEC_REMOTES+=("$SEC_REMOTE")
done

sleep "$POST_AVAIL_SLEEP"
for SEC in "${SEC_REMOTES[@]}"; do
  wait_until_available "$SEC" || warn "Encrypted object $SEC still not ready."
done

# ========================= Download+decrypt (std->legacy) per file ====
HAS_PASS_FLAG=""
has_decrypt_password_flag && HAS_PASS_FLAG=1
i=0
for SEC in "${SEC_REMOTES[@]}"; do
  ((i++))
  DEC_FILE="${WORKDIR}/${SEC}.dec"
  ENC_PASS="$(cat "${PASS_DIR}/${SEC}.pass" 2>/dev/null || true)"
  download_dec_std()    { pipe download-file "$SEC" "$DEC_FILE" --decrypt ${HAS_PASS_FLAG:+--password "$ENC_PASS"}; }
  download_dec_legacy() { pipe download-file "$SEC" "$DEC_FILE" --decrypt --legacy ${HAS_PASS_FLAG:+--password "$ENC_PASS"}; }

  if ! retry_run "Download+decrypt file '$SEC'" "download_dec_std"; then
    warn "Standard decrypt-download failed; trying legacy after short wait…"
    sleep "$RETRY_PAUSE"
    retry_run "Download+decrypt file '$SEC' (legacy)" "download_dec_legacy" || warn "Both streaming and legacy decrypt-download failed for $SEC. Skipping."
  fi
done

# ========================= SHA256 verify per file ======================
for src in "${SRC_FILES[@]}"; do
  base="$(basename "$src")"
  matched=""
  for sec in "${SEC_REMOTES[@]}"; do
    if [[ "$sec" == secure-${base%%.*}-* ]]; then matched="$sec"; break; fi
  done
  if [[ -z "$matched" ]]; then warn "Cannot find decrypted counterpart for ${src} (skipping sha256)"; continue; fi
  DEC_FILE="${WORKDIR}/${matched}.dec"
  if [[ -f "$src" && -f "$DEC_FILE" ]]; then
    SUM_SRC="$(sha256sum "$src" | awk '{print $1}')"
    SUM_DEC="$(sha256sum "$DEC_FILE" | awk '{print $1}')"
    info "SHA256 src (${src}): $SUM_SRC"
    info "SHA256 dec (${DEC_FILE}): $SUM_DEC"
    [[ "$SUM_SRC" == "$SUM_DEC" ]] && ok "SHA256 verification PASSED for ${base}" || err "SHA256 verification FAILED for ${base}"
  else
    warn "SHA256 verification skipped for ${base} (files missing)."
  fi
done

# ========================= Usage report =======================
retry_run "Token usage (30d detailed)" "pipe token-usage --period 30d --detailed || true"

echo -e "\n${GRN}==================== FINAL NOTICE ====================${NC}"
echo -e "   Social media link (for sharing):"
echo -e "   ${BLU}${SOCIAL_LINK:-N/A}${NC}"
echo -e ""
if [[ -f "$CONFIG_FILE" ]]; then
  echo -e "${YEL}[WARNING]${NC} Save this file to restore access on another server:"
  echo -e "  ${BLU}${CONFIG_FILE}${NC}  (contains user_id and user_app_key)"
else
  echo -e "${RED}[ERROR]${NC} Pipe CLI config not found: ${CONFIG_FILE}"
fi
echo -e "${GRN}=======================================================${NC}"
