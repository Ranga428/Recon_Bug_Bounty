# RECON — Bug Bounty Recon Pipeline

```
  ██████╗ ███████╗ ██████╗ ██████╗ ███╗   ██╗
  ██╔══██╗██╔════╝██╔════╝██╔═══██╗████╗  ██║
  ██████╔╝█████╗  ██║     ██║   ██║██╔██╗ ██║
  ██╔══██╗██╔══╝  ██║     ██║   ██║██║╚██╗██║
  ██║  ██║███████╗╚██████╗╚██████╔╝██║ ╚████║
  ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝
```

A modular bash recon pipeline for bug bounty hunters. Point it at a domain or scope file and it automatically runs subdomain enumeration, alive host detection, URL and parameter harvesting, tech fingerprinting, directory fuzzing, screenshots, and vulnerability scanning — then writes everything into a structured markdown report.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Modes](#modes)
- [Pipeline Phases](#pipeline-phases)
- [Output Structure](#output-structure)
- [Tips & Workflow](#tips--workflow)
- [Troubleshooting](#troubleshooting)

---

## Features

- **3 scan modes** — lite, standard, and full — to balance speed vs. depth
- **Automatic HackerOne research header** tagging on all direct requests
- **Subdomain enumeration** via subfinder and amass
- **Alive host detection** with status codes, titles, and tech detection
- **URL & parameter harvesting** from gau (passive) and katana (active crawl)
- **High-value param filtering** for SQLi-prone parameters
- **Tech fingerprinting** with whatweb
- **Directory fuzzing** with ffuf
- **Screenshots** of all alive hosts via gowitness
- **Vulnerability scanning** with nuclei (exposures, medium/high/critical)
- **XSS detection** with dalfox across all param URLs
- **SQL injection testing** with sqlmap on high-value params
- **Port scanning** with nmap (full mode only)
- **Markdown report** auto-generated per target

---

## Requirements

- Linux (tested on Kali)
- Go 1.18+
- Bash / Zsh

---

## Installation

### 1. Clone the repo

```bash
git clone https://github.com/YOUR_USERNAME/recon.git
cd recon
chmod +x recon.sh
```

### 2. Install all dependencies

```bash
./recon.sh --install-deps
```

This installs all required apt packages (`nmap`, `sqlmap`, `whatweb`, `ffuf`, `amass`) and Go tools (`subfinder`, `httpx`, `nuclei`, `katana`, `gau`, `dalfox`, `gowitness`, `assetfinder`). It also pulls the latest nuclei templates.

### 3. Add Go bin to your PATH

The script sets this automatically at runtime, but to make it permanent:

```bash
echo 'export PATH="$(go env GOPATH)/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

> **Note:** Use `~/.bashrc` instead if you're on bash.

### 4. Project structure

When you first run any scan, the script automatically creates two directories:

```
recon/    ← all scan output lands here, one timestamped folder per target
scope/    ← store your scope files here to keep things organised
```

Put your scope files in the `scope/` folder and reference them with `-s`:

```bash
./recon.sh -s scope/getyourguide.txt
./recon.sh -s scope/hackerone_program.txt
```

---

## Configuration

At the top of `recon.sh`, set your HackerOne username:

```bash
H1_USER="YourH1Username"
```

This gets injected as `X-HackerOne-Research: YourH1Username` on all direct HTTP requests (httpx, katana, nuclei, dalfox, ffuf, whatweb). This identifies your traffic to the target's security team and keeps you within responsible disclosure norms.

---

## Usage

```bash
# Single domain
./recon.sh -d target.com

# Scope file (one domain per line)
./recon.sh -s scope.txt

# Full mode with custom thread count
./recon.sh -d target.com -m full -t 100

# Verbose — prints every command before it runs
./recon.sh -d target.com -v

# Show help
./recon.sh -h
./recon.sh --help
```

### Flags

| Flag | Description | Default |
|------|-------------|---------|
| `-d` | Target domain | — |
| `-s` | Scope file (one domain per line) | — |
| `-m` | Mode: `lite`, `standard`, `full` | `standard` |
| `-t` | Thread count | `50` |
| `-v` | Verbose — print each command before running | off |
| `-h` / `--help` | Show usage | — |
| `--install-deps` | Install all required tools | — |

### Scope file format

Scope files live in the `scope/` folder. One bare domain per line — no protocols, no paths, no trailing slashes. Comments and blank lines are ignored.

```
# scope/getyourguide.txt
# Comments and blank lines are ignored

target.com
api.target.com
staging.target.com
```

> **Important:** Use bare domains only. `partner.getyourguide.com` is correct. `https://partner.getyourguide.com/` will break the scan.

Run it with:
```bash
./recon.sh -s scope/getyourguide.txt
```

---

## Modes

### `lite` (~15 min)
Best for quick triage or large scope files. Runs the essential chain only.

```
subfinder → httpx → gau → nuclei (exposures)
```

### `standard` (~45 min) — default
Adds active crawling, directory fuzzing, screenshots, and tech detection.

```
subfinder → httpx → gau → katana → nuclei (exposures)
         → whatweb → ffuf → gowitness
```

### `full` (~1–2 hrs)
Everything in standard, plus port scanning and vulnerability testing.

```
subfinder + amass → httpx → gau → katana → nuclei (exposures + medium/high/critical)
                 → whatweb → ffuf → gowitness
                 → nmap → dalfox → sqlmap
```

---

## Pipeline Phases

### Phase 1 — Subdomain Enumeration
Runs subfinder (all sources) and amass (passive, full mode only). Merges and deduplicates results, then checks all subdomains for alive hosts using httpx with status codes, page titles, and tech detection.

**Output:**
- `subdomains/subfinder.txt` — raw subfinder results
- `subdomains/amass.txt` — raw amass results (full mode)
- `subdomains/all_subs.txt` — merged, deduplicated
- `subdomains/alive.txt` — alive hosts with status + title + tech
- `subdomains/alive_urls.txt` — plain URLs for downstream tools

---

### Phase 2 — URL & Parameter Harvesting
Pulls historical URLs from gau (Wayback Machine + CommonCrawl, passive — no direct requests). In standard/full mode, katana actively crawls all alive hosts up to depth 5.

All URLs are merged, then filtered into:
- URLs containing parameters
- **High-value parameters** matching patterns like `id=`, `user=`, `file=`, `url=`, `redirect=`, `token=`, `debug=`, `admin=`, `path=`, etc.
- **Juicy endpoints** matching patterns like `login`, `admin`, `api`, `upload`, `reset`, `oauth`, `token`, `redirect`, `debug`, `config`, `backup`

**Output:**
- `urls/gau.txt`, `urls/katana.txt` — raw URL sources
- `urls/all_urls.txt` — merged, deduplicated
- `urls/juicy.txt` — filtered high-interest endpoints
- `params/all_params.txt` — all URLs with parameters
- `params/hv_params.txt` — high-value parameter URLs (SQLi candidates)

---

### Phase 3 — Tech Fingerprinting & Content Discovery
Runs whatweb across all alive hosts for technology identification. Nuclei scans for exposures (config files, secrets, sensitive paths). In standard/full mode: gowitness takes screenshots of every alive host, and ffuf fuzzes the main domain for directories using `/usr/share/wordlists/common.txt` or seclists if available.

**Output:**
- `tech/whatweb.txt` — technology fingerprint results
- `vulns/nuclei_exposures.txt` — nuclei exposure findings
- `screenshots/` — gowitness screenshots
- `urls/ffuf.json` — ffuf directory fuzz results

---

### Phase 4 — Port Scanning *(full mode only)*
Runs nmap with service detection (`-sV`) against the main domain, scanning the top 1000 ports.

**Output:**
- `ports/nmap.txt` — nmap scan results

---

### Phase 5 — Vulnerability Scanning *(full mode only)*
Three parallel vulnerability checks:

1. **nuclei** — scans all alive hosts with medium/high/critical severity templates
2. **dalfox** — XSS testing across every URL with parameters
3. **sqlmap** — SQL injection testing on high-value parameter URLs only (batched, level 2, risk 2)

**Output:**
- `vulns/nuclei_full.txt` — nuclei vulnerability findings
- `vulns/dalfox.txt` — XSS findings
- `vulns/sqlmap/` — sqlmap session output per URL

---

## Output Structure

Each run creates a timestamped directory under `recon/`:

```
recon/
└── target.com_2026-04-04_02-04-24/
    ├── report.md               ← auto-generated markdown report
    ├── recon.log               ← full tool output / errors
    ├── subdomains/
    │   ├── subfinder.txt
    │   ├── amass.txt           (full mode only)
    │   ├── all_subs.txt
    │   ├── alive.txt
    │   └── alive_urls.txt
    ├── urls/
    │   ├── gau.txt
    │   ├── katana.txt          (standard/full)
    │   ├── all_urls.txt
    │   ├── juicy.txt
    │   └── ffuf.json           (standard/full)
    ├── params/
    │   ├── all_params.txt
    │   └── hv_params.txt
    ├── ports/
    │   └── nmap.txt            (full only)
    ├── screenshots/            (standard/full)
    ├── tech/
    │   └── whatweb.txt
    └── vulns/
        ├── nuclei_exposures.txt
        ├── nuclei_full.txt     (full only)
        ├── dalfox.txt          (full only)
        └── sqlmap/             (full only)
```

The `report.md` in each run directory contains a summary table and the top 100 lines of each output file for quick review.

---

## Tips & Workflow

**Start with lite on a new target** to get the lay of the land fast, then escalate to full on interesting subdomains.

```bash
./recon.sh -d target.com -m lite
# review output, identify interesting subdomains
./recon.sh -d interesting.target.com -m full
```

**Check juicy endpoints first** — these are your highest-signal starting points:

```bash
cat recon/target.com_*/urls/juicy.txt
```

**Review high-value params for manual testing** — sqlmap won't catch everything:

```bash
cat recon/target.com_*/params/hv_params.txt
```

**IDOR hunting** — the `partner_id=` style params in harvested URLs are worth testing manually for insecure direct object references. Swap values, check for different user responses.

**Use verbose mode when debugging** to see exactly what's being run:

```bash
./recon.sh -d target.com -v 2>&1 | tee debug.log
```

**Run multiple domains in parallel** using a scope file — the pipeline loops through each domain sequentially, but you can background the whole thing:

```bash
nohup ./recon.sh -s scope.txt -m standard > output.log 2>&1 &
tail -f output.log
```

---

## Troubleshooting

### Tools not found after install

The Go binary path may not be in your shell's PATH. Add it permanently:

```bash
echo 'export PATH="$(go env GOPATH)/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Then open a fresh terminal and verify:

```bash
which subfinder httpx nuclei katana
```

### Wrong `httpx` binary

Kali ships a Python-based `httpx` at `/usr/bin/httpx`. The script forces Go's bin path to the front of PATH at runtime to override this. If you still see issues, verify which one is running:

```bash
httpx --version
# Should output something like: projectdiscovery/httpx v1.x.x
```

If it shows a Python version, reinstall the Go version:

```bash
go install github.com/projectdiscovery/httpx/cmd/httpx@latest
```

### Nuclei "no templates" error

Templates are expected at `~/nuclei-templates`. Update them with:

```bash
nuclei -update-templates
```

### ffuf skipped — no wordlist found

Install seclists:

```bash
sudo apt install seclists
```

Or set a wordlist manually by editing the `phase_tech_and_fuzz` function in the script.

### `gau.toml` config warning

This warning is harmless — gau runs fine without a config file. To suppress it, create an empty config:

```bash
touch ~/.gau.toml
```

---

## Disclaimer

This tool is intended for authorized security testing only. Only run it against targets you have explicit permission to test. Always operate within the scope defined by the bug bounty program. The author is not responsible for misuse.
