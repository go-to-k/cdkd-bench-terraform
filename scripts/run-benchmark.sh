#!/usr/bin/env bash
#
# run-benchmark.sh - Deploy speed: cdkd vs cdkd --no-wait vs CloudFormation vs Terraform
#
# Usage:
#   ./scripts/run-benchmark.sh [tools] [scenario]
#     tools:    comma list of cdkd,cdkd-nowait,cfn,tf   (default: all)
#     scenario: webapp | wide                            (default: webapp)
#
# Env:
#   AWS_REGION   (default us-east-1)
#   CDKD_BIN     (default /Users/goto/pc/github/cdkd/dist/cli.js)
#   RUNS         (default 3; the MEDIAN deploy time is reported)
#   WIDE_COUNT   (wide scenario: N of each resource type; default 8)
#
# Measures the single cold end-to-end deploy wall-time per tool. One-time setup
# (npm install / cdk bootstrap / terraform init) is done up-front, not timed.
#
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CDK_DIR="$ROOT/cdk"
RESULTS_DIR="$ROOT/results"

AWS_REGION="${AWS_REGION:-us-east-1}"; export AWS_REGION CDK_DEFAULT_REGION="$AWS_REGION"
CDKD_BIN="${CDKD_BIN:-/Users/goto/pc/github/cdkd/dist/cli.js}"
RUNS="${RUNS:-3}"
TOOLS="${1:-cdkd,cdkd-nowait,cfn,tf}"
SCENARIO="${2:-webapp}"
export WIDE_COUNT="${WIDE_COUNT:-8}"

case "$SCENARIO" in
  webapp)     STACK="BenchWebApp";     TF_DIR="$ROOT/terraform";            TF_VARS=(-var "region=$AWS_REGION");;
  wide)       STACK="BenchWide";       TF_DIR="$ROOT/terraform/wide";       TF_VARS=(-var "region=$AWS_REGION" -var "count_each=$WIDE_COUNT");;
  serverless) STACK="BenchServerless"; TF_DIR="$ROOT/terraform/serverless"; TF_VARS=(-var "region=$AWS_REGION");;
  cloudfront) STACK="BenchCloudFront"; TF_DIR="$ROOT/terraform/cloudfront"; TF_VARS=(-var "region=$AWS_REGION");;
  *) echo "unknown scenario: $SCENARIO (webapp|wide|serverless|cloudfront)"; exit 1;;
esac
# `cdkd --no-wait` deploys the distinct `*Nw` twin stack so its resource names
# never collide with the plain-cdkd stack (SQS 60s name-reuse cooldown).
NW_STACK="${STACK}Nw"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC}  $*"; }
ok(){ echo -e "${GREEN}[OK]${NC}    $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC}  $*"; }
err(){ echo -e "${RED}[ERROR]${NC} $*"; }
phase(){ echo -e "${CYAN}>>> $*${NC}"; }
now_ms(){ python3 -c 'import time;print(int(time.time()*1000))'; }
fmt(){ python3 -c "print('N/A' if $1==0 else f'{$1/1000:.1f}s')"; }
median(){ python3 -c "import sys,statistics as s; xs=[int(x) for x in sys.argv[1:] if int(x)>0]; print(int(s.median(xs)) if xs else 0)" "$@"; }
has(){ [[ ",$TOOLS," == *",$1,"* ]]; }

declare -a CDKD_T=() NOWAIT_T=() CFN_T=() TF_T=()

setup(){
  phase "Preflight ($SCENARIO / tools=$TOOLS / RUNS=$RUNS)"
  aws sts get-caller-identity >/dev/null || { err "no creds"; exit 1; }
  ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"; export CDK_DEFAULT_ACCOUNT="$ACCOUNT"
  ok "account=$ACCOUNT region=$AWS_REGION cdkd=$(node "$CDKD_BIN" --version 2>/dev/null)"
  [[ -d "$CDK_DIR/node_modules" ]] || (cd "$CDK_DIR" && npm install >/dev/null 2>&1)
  if has cdkd || has cdkd-nowait || has cfn; then
    (cd "$CDK_DIR" && npx cdk bootstrap "aws://$ACCOUNT/$AWS_REGION" >/dev/null 2>&1) || warn "bootstrap non-zero"
  fi
  if has tf; then
    command -v terraform >/dev/null || { err "terraform missing"; exit 1; }
    (cd "$TF_DIR" && terraform init -input=false >/dev/null 2>&1) || { err "tf init failed"; exit 1; }
  fi
  mkdir -p "$RESULTS_DIR"; echo ""
}

cdkd_destroy(){ (cd "$CDK_DIR" && node "$CDKD_BIN" destroy --app "node bin/app.ts" --force "${1:-$STACK}" >/dev/null 2>&1) || true; }
cfn_destroy(){  (cd "$CDK_DIR" && npx cdk destroy "$STACK" --force >/dev/null 2>&1) || true; }
tf_destroy(){   (cd "$TF_DIR" && terraform destroy -auto-approve -input=false "${TF_VARS[@]}" >/dev/null 2>&1) || true; }

time_cdkd(){ # $1 = extra flag (--no-wait or empty), $2 = log, $3 = stack (default $STACK)
  local stk="${3:-$STACK}"
  cdkd_destroy "$stk"
  local t; t=$(now_ms)
  (cd "$CDK_DIR" && node "$CDKD_BIN" deploy --app "node bin/app.ts" $1 "$stk" >"$2" 2>&1); local rc=$?
  local ms=$(( $(now_ms)-t )); cdkd_destroy "$stk"
  [[ $rc -ne 0 ]] && { err "cdkd $1 rc=$rc (see $2)"; tail -12 "$2"; echo 0; return; }
  echo "$ms"
}
time_cfn(){
  cfn_destroy
  local t=$(now_ms)
  (cd "$CDK_DIR" && npx cdk deploy "$STACK" --require-approval never >"$1" 2>&1); local rc=$?
  local ms=$(( $(now_ms)-t )); cfn_destroy
  [[ $rc -ne 0 ]] && { err "cfn rc=$rc"; tail -12 "$1"; echo 0; return; }
  echo "$ms"
}
time_tf(){
  tf_destroy
  local t=$(now_ms)
  (cd "$TF_DIR" && terraform apply -auto-approve -input=false "${TF_VARS[@]}" >"$1" 2>&1); local rc=$?
  local ms=$(( $(now_ms)-t )); tf_destroy
  [[ $rc -ne 0 ]] && { err "tf rc=$rc"; tail -12 "$1"; echo 0; return; }
  echo "$ms"
}

report(){
  local ts; ts="$(date '+%Y%m%d-%H%M%S')"; local out="$RESULTS_DIR/results-$SCENARIO-$ts.md"
  local m_cdkd m_nowait m_cfn m_tf
  m_cdkd=$(median "${CDKD_T[@]:-0}"); m_nowait=$(median "${NOWAIT_T[@]:-0}"); m_cfn=$(median "${CFN_T[@]:-0}"); m_tf=$(median "${TF_T[@]:-0}")
  {
    echo "# Benchmark: $SCENARIO stack"
    echo ""
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S')  Region: $AWS_REGION  RUNS: $RUNS (median)"
    echo "- cdkd: $(node "$CDKD_BIN" --version 2>/dev/null)  cdk: $(cd "$CDK_DIR" && npx cdk --version 2>/dev/null)  terraform: $(terraform --version 2>/dev/null | head -1)"
    [[ "$SCENARIO" == wide ]] && echo "- WIDE_COUNT: $WIDE_COUNT of each (S3/DDB/SQS/SNS/SSM/Logs)"
    echo ""
    echo "Metric = median cold end-to-end deploy wall-time (setup untimed)."
    echo ""
    echo "| Tool | Deploy (median) | all runs |"
    echo "|---|---|---|"
    has cdkd        && echo "| cdkd | $(fmt $m_cdkd) | $(for x in "${CDKD_T[@]}"; do printf '%s ' "$(fmt $x)"; done) |"
    has cdkd-nowait && echo "| cdkd --no-wait | $(fmt $m_nowait) | $(for x in "${NOWAIT_T[@]}"; do printf '%s ' "$(fmt $x)"; done) |"
    has cfn         && echo "| CloudFormation | $(fmt $m_cfn) | $(for x in "${CFN_T[@]}"; do printf '%s ' "$(fmt $x)"; done) |"
    has tf          && echo "| Terraform | $(fmt $m_tf) | $(for x in "${TF_T[@]}"; do printf '%s ' "$(fmt $x)"; done) |"
  } | tee "$out"
  echo ""; info "saved: $out"
}

main(){
  setup
  for ((i=1;i<=RUNS;i++)); do
    info "=== run $i/$RUNS ($SCENARIO) ==="
    has cdkd        && { phase "cdkd (run $i)";        CDKD_T+=("$(time_cdkd '' "$RESULTS_DIR/cdkd-$SCENARIO.log")");        ok "cdkd $(fmt ${CDKD_T[-1]})"; }
    has cdkd-nowait && { phase "cdkd --no-wait (run $i)"; NOWAIT_T+=("$(time_cdkd '--no-wait' "$RESULTS_DIR/nowait-$SCENARIO.log" "$NW_STACK")"); ok "cdkd --no-wait $(fmt ${NOWAIT_T[-1]})"; }
    has cfn         && { phase "CloudFormation (run $i)"; CFN_T+=("$(time_cfn "$RESULTS_DIR/cfn-$SCENARIO.log")");            ok "cfn $(fmt ${CFN_T[-1]})"; }
    has tf          && { phase "Terraform (run $i)";     TF_T+=("$(time_tf "$RESULTS_DIR/tf-$SCENARIO.log")");                ok "tf $(fmt ${TF_T[-1]})"; }
  done
  report
}
main
