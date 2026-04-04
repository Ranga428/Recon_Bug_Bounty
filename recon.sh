#!/bin/bash

# ============================================================
#  recon.sh — Bug Bounty Recon Pipeline
#  Usage:
#    recon.sh --install-deps
#    recon.sh -d target.com
#    recon.sh -s scope.txt
#    recon.sh -d target.com -m full -t 100
# ============================================================

# ---------- colours ----------
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
MAG='\033[0;35m'
BOLD='\033[1m'
RST='\033[0m'

# ---------- defaults ----------
MODE="standard"
THREADS=50
DOMAINS=()
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
VERBOSE=false

# ---------- HackerOne research header ----------
H1_USER="RangaPT"
H1_HEADER="X-HackerOne-Research: ${H1_USER}"

# ---------- force Go bin path so PD tools take priority over system tools ----------
export PATH="$(go env GOPATH)/bin:$PATH"

# ---------- nuclei templates ----------
NUCLEI_TEMPLATES="/home/kali/nuclei-templates"

# ---------- high-value param patterns for sqlmap ----------
HV_PARAMS="id=|user=|uid=|file=|url=|redirect=|token=|debug=|admin=|ref=|page=|path=|dir=|item=|order="

# ============================================================
# BANNER
# ============================================================
banner() {
  echo -e "${CYN}${BOLD}"
  cat << 'EOF'
  ██████╗ ███████╗ ██████╗ ██████╗ ███╗   ██╗
  ██╔══██╗██╔════╝██╔════╝██╔═══██╗████╗  ██║
  ██████╔╝█████╗  ██║     ██║   ██║██╔██╗ ██║
  ██╔══██╗██╔══╝  ██║     ██║   ██║██║╚██╗██║
  ██║  ██║███████╗╚██████╗╚██████╔╝██║ ╚████║
  ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝
  Bug Bounty Recon Pipeline
EOF
  echo -e "${RST}"
}

# ============================================================
# HELP
# ============================================================
usage() {
  echo -e "${BOLD}Usage:${RST}"
  echo "  $0 --install-deps           Install all tools (run once before first use)"
  echo "  $0 -d <domain>              Single domain"
  echo "  $0 -s <scope.txt>           Scope file (one domain per line)"
  echo ""
  echo -e "${BOLD}Options:${RST}"
  echo "  -d  Target domain"
  echo "  -s  Scope file"
  echo "  -m  Mode: lite | standard | full  (default: standard)"
  echo "  -t  Threads (default: 50)"
  echo "  -v  Verbose — print each command before it runs"
  echo "  -h  Help"
  echo ""
  echo -e "${BOLD}Modes:${RST}"
  echo "  lite      subfinder → httpx → gau → nuclei exposures           (~15 min)"
  echo "  standard  + katana + ffuf + whatweb + gowitness                (~45 min)"
  echo "  full      + nmap + dalfox (all params) + sqlmap (HV params)  (~1-2 hrs)"
  exit 0
}

# ============================================================
# LOGGING HELPERS
# ============================================================
info()    { echo -e "${BLU}[*]${RST} $1"; }
success() { echo -e "${GRN}[+]${RST} $1"; }
warn()    { echo -e "${YLW}[!]${RST} $1"; }
error()   { echo -e "${RED}[-]${RST} $1"; }
section() { echo -e "\n${MAG}${BOLD}━━━ $1 ━━━${RST}"; }

# print command if -v is set, then execute it
run_cmd() {
  if [[ "$VERBOSE" == true ]]; then
    echo -e "${CYN}[CMD]${RST} $*"
  fi
  "$@"
}

# ============================================================
# INSTALL DEPENDENCIES
# ============================================================
install_deps() {
  section "Installing Dependencies"

  # ── check go ──────────────────────────────────────────────
  if ! command -v go &>/dev/null; then
    error "Go is not installed. Install it first:"
    echo "  https://go.dev/doc/install"
    echo "  or: sudo apt install golang-go"
    exit 1
  fi
  success "Go found: $(go version)"

  # make sure ~/go/bin is in PATH for this session
  export PATH="$PATH:$(go env GOPATH)/bin"

  # ── apt tools ─────────────────────────────────────────────
  section "apt packages"
  local apt_tools=("nmap" "sqlmap" "whatweb" "ffuf" "amass")
  local apt_missing=()

  for t in "${apt_tools[@]}"; do
    command -v "$t" &>/dev/null && success "$t already installed" || apt_missing+=("$t")
  done

  if [[ ${#apt_missing[@]} -gt 0 ]]; then
    info "Installing: ${apt_missing[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${apt_missing[@]}"
    for t in "${apt_missing[@]}"; do
      command -v "$t" &>/dev/null \
        && success "$t installed" \
        || error "$t failed to install — check apt output above"
    done
  fi

  # ── go tools ──────────────────────────────────────────────
  section "go install tools"

  declare -A GO_TOOLS=(
    [subfinder]="github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    [httpx]="github.com/projectdiscovery/httpx/cmd/httpx@latest"
    [nuclei]="github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
    [katana]="github.com/projectdiscovery/katana/cmd/katana@latest"
    [gau]="github.com/lc/gau/v2/cmd/gau@latest"
    [dalfox]="github.com/hahwul/dalfox/v2@latest"
    [gowitness]="github.com/sensepost/gowitness@latest"
    [assetfinder]="github.com/tomnomnom/assetfinder@latest"
  )

  for tool in "${!GO_TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
      success "$tool already installed"
    else
      info "Installing $tool..."
      go install "${GO_TOOLS[$tool]}" 2>&1 | tail -1
      command -v "$tool" &>/dev/null \
        && success "$tool installed" \
        || error "$tool failed — check go install output above"
    fi
  done

  # ── nuclei templates ──────────────────────────────────────
  section "Nuclei Templates"
  if command -v nuclei &>/dev/null; then
    info "Updating nuclei templates..."
    nuclei -update-templates 2>&1 | tail -3
    success "Templates updated"
  fi

  # ── PATH reminder ─────────────────────────────────────────
  echo ""
  warn "If go tools are not found in future sessions, add this to your ~/.zshrc:"
  echo '  export PATH="$PATH:$(go env GOPATH)/bin"'
  echo ""
  success "All done. Run: ./recon.sh -h"
  exit 0
}

# ============================================================
# TOOL CHECK
# ============================================================
check_tools() {
  local required=("subfinder" "httpx" "gau" "nuclei")
  local standard=("katana" "ffuf" "whatweb" "gowitness")
  local full_tools=("nmap" "dalfox" "sqlmap")

  local missing=()

  for t in "${required[@]}"; do
    command -v "$t" &>/dev/null || missing+=("$t")
  done

  if [[ "$MODE" == "standard" || "$MODE" == "full" ]]; then
    for t in "${standard[@]}"; do
      command -v "$t" &>/dev/null || missing+=("$t")
    done
  fi

  if [[ "$MODE" == "full" ]]; then
    for t in "${full_tools[@]}"; do
      command -v "$t" &>/dev/null || missing+=("$t")
    done
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing tools: ${missing[*]}"
    error "Run: $0 --install-deps"
    exit 1
  fi

  success "All required tools present for mode: ${BOLD}${MODE}${RST}"
}

# ============================================================
# SETUP OUTPUT DIRS
# ============================================================
setup_dirs() {
  local domain=$1
  OUT="recon/${domain}_${TIMESTAMP}"
  mkdir -p "$OUT"/{subdomains,urls,params,ports,screenshots,vulns,tech}
  LOG="$OUT/recon.log"
  REPORT="$OUT/report.md"
  info "Output → ${BOLD}$OUT${RST}"
}

# ============================================================
# REPORT HELPERS
# ============================================================
report_init() {
  local domain=$1
  cat > "$REPORT" << EOF
# Recon Report — ${domain}
**Date:** $(date)
**Mode:** ${MODE}
**Threads:** ${THREADS}

---

EOF
}

report_section() {
  echo -e "\n## $1\n" >> "$REPORT"
}

report_append() {
  echo "$1" >> "$REPORT"
}

report_file() {
  # append file contents under a code block
  local label=$1 file=$2
  if [[ -s "$file" ]]; then
    echo -e "\n\`\`\`" >> "$REPORT"
    head -n 100 "$file" >> "$REPORT"   # cap at 100 lines in report
    local total
    total=$(wc -l < "$file")
    [[ $total -gt 100 ]] && echo "... ($total lines total — see $file)" >> "$REPORT"
    echo '```' >> "$REPORT"
  else
    echo "_No results._" >> "$REPORT"
  fi
}

# ============================================================
# PHASE 1 — SUBDOMAIN ENUMERATION (all modes)
# ============================================================
phase_subdomains() {
  local domain=$1
  section "Phase 1 — Subdomain Enumeration"

  info "Running subfinder..."
  run_cmd subfinder -d "$domain" -all -silent 2>>"$LOG" > "$OUT/subdomains/subfinder.txt"
  success "subfinder: $(wc -l < "$OUT/subdomains/subfinder.txt") results"

  if [[ "$MODE" == "full" ]]; then
    info "Running amass (passive)..."
    run_cmd amass enum -passive -d "$domain" -o "$OUT/subdomains/amass.txt" 2>>"$LOG" || true
    success "amass: $(wc -l < "$OUT/subdomains/amass.txt" 2>/dev/null || echo 0) results"
  fi

  # merge & deduplicate
  cat "$OUT/subdomains/"*.txt 2>/dev/null | sort -u > "$OUT/subdomains/all_subs.txt"
  success "Total unique subdomains: $(wc -l < "$OUT/subdomains/all_subs.txt")"

  # alive check — FIX: use -list instead of -l
  info "Checking alive hosts (httpx, threads: ${THREADS})..."
  run_cmd httpx -list "$OUT/subdomains/all_subs.txt" \
        -threads "$THREADS" \
        -silent \
        -status-code \
        -title \
        -tech-detect \
        -H "${H1_HEADER}" \
        -o "$OUT/subdomains/alive.txt" 2>>"$LOG"
  success "Alive hosts: $(wc -l < "$OUT/subdomains/alive.txt")"

  # plain alive URLs for downstream tools
  awk '{print $1}' "$OUT/subdomains/alive.txt" > "$OUT/subdomains/alive_urls.txt"

  report_section "Subdomains"
  report_append "**Total found:** $(wc -l < "$OUT/subdomains/all_subs.txt")"
  report_append "**Alive:** $(wc -l < "$OUT/subdomains/alive.txt")"
  report_file "Alive hosts" "$OUT/subdomains/alive.txt"
}

# ============================================================
# PHASE 2 — URL & PARAM HARVESTING (all modes)
# ============================================================
phase_urls() {
  local domain=$1
  section "Phase 2 — URL & Parameter Harvesting"

  # gau does not support custom headers — passive/archive tool, no direct requests
  info "Running gau..."
  run_cmd gau "$domain" --threads "$THREADS" --o "$OUT/urls/gau.txt" 2>>"$LOG" || true
  success "gau: $(wc -l < "$OUT/urls/gau.txt" 2>/dev/null || echo 0) URLs"

  if [[ "$MODE" == "standard" || "$MODE" == "full" ]]; then
    info "Running katana..."
    run_cmd katana -list "$OUT/subdomains/alive_urls.txt" \
           -d 5 \
           -c "$THREADS" \
           -silent \
           -H "${H1_HEADER}" \
           -o "$OUT/urls/katana.txt" 2>>"$LOG" || true
    success "katana: $(wc -l < "$OUT/urls/katana.txt" 2>/dev/null || echo 0) URLs"
  fi

  # merge
  cat "$OUT/urls/"*.txt 2>/dev/null | sort -u > "$OUT/urls/all_urls.txt"
  success "Total unique URLs: $(wc -l < "$OUT/urls/all_urls.txt")"

  # extract params
  grep "=" "$OUT/urls/all_urls.txt" | sort -u > "$OUT/params/all_params.txt"
  success "URLs with params: $(wc -l < "$OUT/params/all_params.txt")"

  # filter high-value params
  grep -E "$HV_PARAMS" "$OUT/params/all_params.txt" > "$OUT/params/hv_params.txt" || true
  success "High-value param URLs: $(wc -l < "$OUT/params/hv_params.txt" 2>/dev/null || echo 0)"

  # filter juicy endpoints
  grep -iE "login|admin|api|upload|reset|forgot|oauth|token|redirect|debug|config|backup" \
       "$OUT/urls/all_urls.txt" > "$OUT/urls/juicy.txt" || true
  success "Juicy endpoints: $(wc -l < "$OUT/urls/juicy.txt")"

  report_section "URLs & Parameters"
  report_append "**Total URLs:** $(wc -l < "$OUT/urls/all_urls.txt")"
  report_append "**URLs with params:** $(wc -l < "$OUT/params/all_params.txt")"
  report_append "**High-value param URLs:** $(wc -l < "$OUT/params/hv_params.txt" 2>/dev/null || echo 0)"
  report_append "\n### Juicy Endpoints"
  report_file "Juicy" "$OUT/urls/juicy.txt"
}

# ============================================================
# PHASE 3 — TECH FINGERPRINT + DIR FUZZ (standard + full)
# ============================================================
phase_tech_and_fuzz() {
  local domain=$1
  section "Phase 3 — Tech Fingerprinting & Content Discovery"

  # FIX: whatweb header syntax — use -add-header with colon-separated value
  info "Running whatweb..."
  run_cmd whatweb --input-file="$OUT/subdomains/alive_urls.txt" \
          -H "X-HackerOne-Research: ${H1_USER}" \
          --log-brief="$OUT/tech/whatweb.txt" 2>>"$LOG" || true
  success "whatweb done"

  # FIX: nuclei — point to actual templates directory
  info "Running nuclei (exposures)..."
  run_cmd nuclei -list "$OUT/subdomains/alive_urls.txt" \
         -t "${NUCLEI_TEMPLATES}/http/exposures/" \
         -c "$THREADS" \
         -silent \
         -H "${H1_HEADER}" \
         -o "$OUT/vulns/nuclei_exposures.txt" 2>>"$LOG" || true
  success "nuclei exposures: $(wc -l < "$OUT/vulns/nuclei_exposures.txt" 2>/dev/null || echo 0) findings"

  if [[ "$MODE" == "standard" || "$MODE" == "full" ]]; then
    # gowitness does not support custom headers natively — skipped
    info "Running gowitness (screenshots)..."
    run_cmd gowitness file -f "$OUT/subdomains/alive_urls.txt" \
              --destination "$OUT/screenshots/" 2>>"$LOG" || true
    success "Screenshots saved to $OUT/screenshots/"

    if command -v ffuf &>/dev/null; then
      local wordlist
      wordlist=$(find /usr/share/wordlists -name "common.txt" 2>/dev/null | head -1)
      if [[ -z "$wordlist" ]]; then
        wordlist=$(find /usr/share/seclists -name "raft-medium-directories.txt" 2>/dev/null | head -1)
      fi
      if [[ -n "$wordlist" ]]; then
        info "Running ffuf on main domain..."
        run_cmd ffuf -u "https://${domain}/FUZZ" \
             -w "$wordlist" \
             -t "$THREADS" \
             -mc 200,201,301,302,403 \
             -H "${H1_HEADER}" \
             -o "$OUT/urls/ffuf.json" \
             -of json \
             -s 2>>"$LOG" || true
        success "ffuf done"
      else
        warn "No wordlist found for ffuf — skipping. Install seclists or set wordlist manually."
      fi
    fi
  fi

  report_section "Tech & Content Discovery"
  report_append "\n### Nuclei Exposures"
  report_file "Exposures" "$OUT/vulns/nuclei_exposures.txt"
  report_append "\n### WhatWeb"
  report_file "WhatWeb" "$OUT/tech/whatweb.txt"
}

# ============================================================
# PHASE 4 — PORT SCAN (full only)
# ============================================================
phase_ports() {
  local domain=$1
  section "Phase 4 — Port Scanning (nmap)"

  # nmap operates at TCP/IP level — HTTP headers do not apply
  info "Scanning top 1000 ports on main domain..."
  run_cmd nmap -sV -T4 --open \
       -oN "$OUT/ports/nmap.txt" \
       "$domain" 2>>"$LOG" || true
  success "nmap done → $OUT/ports/nmap.txt"

  report_section "Port Scan"
  report_file "nmap" "$OUT/ports/nmap.txt"
}

# ============================================================
# PHASE 5 — VULN SCANNING (full only)
# ============================================================
phase_vulns() {
  section "Phase 5 — Vulnerability Scanning"

  # FIX: nuclei — point to actual templates directory
  info "Running nuclei (medium/high/critical)..."
  run_cmd nuclei -list "$OUT/subdomains/alive_urls.txt" \
         -t "${NUCLEI_TEMPLATES}/" \
         -severity medium,high,critical \
         -c "$THREADS" \
         -silent \
         -H "${H1_HEADER}" \
         -o "$OUT/vulns/nuclei_full.txt" 2>>"$LOG" || true
  success "nuclei full: $(wc -l < "$OUT/vulns/nuclei_full.txt" 2>/dev/null || echo 0) findings"

  if [[ -s "$OUT/params/all_params.txt" ]]; then
    info "Running dalfox on all param URLs..."
    run_cmd dalfox file "$OUT/params/all_params.txt" \
           --skip-bav \
           --header "${H1_HEADER}" \
           --output "$OUT/vulns/dalfox.txt" 2>>"$LOG" || true
    success "dalfox: $(wc -l < "$OUT/vulns/dalfox.txt" 2>/dev/null || echo 0) findings"
  else
    warn "No param URLs found — skipping dalfox"
  fi

  if [[ -s "$OUT/params/hv_params.txt" ]]; then
    info "Running sqlmap on high-value param URLs..."
    local sqli_out="$OUT/vulns/sqlmap/"
    mkdir -p "$sqli_out"
    while IFS= read -r url; do
      run_cmd sqlmap -u "$url" \
             --batch \
             --level=2 \
             --risk=2 \
             --threads="$THREADS" \
             --headers="${H1_HEADER}" \
             --output-dir="$sqli_out" \
             --quiet 2>>"$LOG" || true
    done < "$OUT/params/hv_params.txt"
    success "sqlmap done → $sqli_out"
  else
    warn "No high-value param URLs found — skipping sqlmap"
  fi

  report_section "Vulnerability Findings"
  report_append "\n### Nuclei (medium/high/critical)"
  report_file "nuclei" "$OUT/vulns/nuclei_full.txt"
  report_append "\n### Dalfox XSS"
  report_file "dalfox" "$OUT/vulns/dalfox.txt"
}

# ============================================================
# FINAL REPORT SUMMARY
# ============================================================
finalize_report() {
  local domain=$1
  cat >> "$REPORT" << EOF

---

## Summary

| Category | Count |
|---|---|
| Subdomains found | $(wc -l < "$OUT/subdomains/all_subs.txt" 2>/dev/null || echo 0) |
| Alive hosts | $(wc -l < "$OUT/subdomains/alive_urls.txt" 2>/dev/null || echo 0) |
| Total URLs | $(wc -l < "$OUT/urls/all_urls.txt" 2>/dev/null || echo 0) |
| URLs with params | $(wc -l < "$OUT/params/all_params.txt" 2>/dev/null || echo 0) |
| High-value param URLs | $(wc -l < "$OUT/params/hv_params.txt" 2>/dev/null || echo 0) |
| Juicy endpoints | $(wc -l < "$OUT/urls/juicy.txt" 2>/dev/null || echo 0) |
| Nuclei findings | $(cat "$OUT/vulns/nuclei_"*.txt 2>/dev/null | wc -l || echo 0) |
| Dalfox XSS | $(wc -l < "$OUT/vulns/dalfox.txt" 2>/dev/null || echo 0) |

**Output directory:** \`$OUT\`

EOF
  success "Report → ${BOLD}$REPORT${RST}"
}

# ============================================================
# RUN PIPELINE FOR ONE DOMAIN
# ============================================================
run_domain() {
  local domain=$1
  echo -e "\n${BOLD}${CYN}══════════════════════════════════════${RST}"
  echo -e "${BOLD}  Target: ${YLW}${domain}${RST}"
  echo -e "${BOLD}  Mode:   ${YLW}${MODE}${RST}"
  echo -e "${BOLD}  Threads:${YLW}${THREADS}${RST}"
  echo -e "${CYN}══════════════════════════════════════${RST}\n"

  setup_dirs "$domain"
  report_init "$domain"

  # Phase 1 — always
  phase_subdomains "$domain"

  # Phase 2 — always
  phase_urls "$domain"

  # Phase 3 — standard + full
  if [[ "$MODE" == "standard" || "$MODE" == "full" ]]; then
    phase_tech_and_fuzz "$domain"
  else
    # lite still gets nuclei exposures
    section "Phase 3 — Nuclei Exposures (lite)"
    run_cmd nuclei -list "$OUT/subdomains/alive_urls.txt" \
           -t "${NUCLEI_TEMPLATES}/http/exposures/" \
           -c "$THREADS" \
           -silent \
           -H "${H1_HEADER}" \
           -o "$OUT/vulns/nuclei_exposures.txt" 2>>"$LOG" || true
    success "nuclei exposures: $(wc -l < "$OUT/vulns/nuclei_exposures.txt" 2>/dev/null || echo 0) findings"
    report_section "Nuclei Exposures"
    report_file "Exposures" "$OUT/vulns/nuclei_exposures.txt"
  fi

  # Phase 4 — full only
  if [[ "$MODE" == "full" ]]; then
    phase_ports "$domain"
    phase_vulns
  fi

  finalize_report "$domain"
}

# ============================================================
# PARSE ARGS
# ============================================================
banner

if [[ $# -eq 0 ]]; then usage; fi

# handle long flags before getopts
if [[ "$1" == "--install-deps" ]]; then
  install_deps
fi

if [[ "$1" == "--help" ]]; then
  usage
fi

while getopts ":d:s:m:t:vh" opt; do
  case $opt in
    d) DOMAINS+=("$OPTARG") ;;
    s)
      if [[ ! -f "$OPTARG" ]]; then
        error "Scope file not found: $OPTARG"; exit 1
      fi
      while IFS= read -r line; do
        # strip whitespace, skip comments and blanks
        line=$(echo "$line" | tr -d '[:space:]')
        [[ -z "$line" || "$line" == \#* ]] && continue
        DOMAINS+=("$line")
      done < "$OPTARG"
      ;;
    m)
      if [[ "$OPTARG" != "lite" && "$OPTARG" != "standard" && "$OPTARG" != "full" ]]; then
        error "Mode must be: lite | standard | full"; exit 1
      fi
      MODE="$OPTARG"
      ;;
    t)
      if ! [[ "$OPTARG" =~ ^[0-9]+$ ]]; then
        error "Threads must be a number"; exit 1
      fi
      THREADS="$OPTARG"
      ;;
    v) VERBOSE=true ;;
    h) usage ;;
    :) error "Option -$OPTARG requires an argument"; exit 1 ;;
    \?) error "Unknown option: -$OPTARG"; exit 1 ;;
  esac
done

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  error "No target specified. Use -d or -s."; usage
fi

check_tools

mkdir -p recon

# ============================================================
# MAIN LOOP
# ============================================================
for domain in "${DOMAINS[@]}"; do
  run_domain "$domain"
done

echo -e "\n${GRN}${BOLD}All done.${RST} Results in: ${BOLD}recon/${RST}\n"
