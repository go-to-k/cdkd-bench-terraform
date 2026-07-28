#!/usr/bin/env bash
#
# run-benchmark.sh - Deploy speed: cdkd vs CloudFormation vs Terraform
#
# Usage:
#   ./scripts/run-benchmark.sh [tools] [scenario]
#     tools:    comma list of cdkd,cdkd-nowait,cdkd-fullwait,cfn,tf,tf-nowait,tf-fullwait
#               (default: cdkd,cdkd-nowait,cfn,tf)
#     scenario: webapp | wide | serverless | cloudfront | ec2 | ecs
#               (default: webapp)
#
# Env:
#   AWS_REGION   (default us-east-1)
#   CDKD_BIN     (default $(dirname $0)/../../cdkd/dist/cli.js -- the SIBLING
#                cdkd checkout's dist. When measuring an unmerged fix, export
#                this explicitly at the worktree you built, and confirm with
#                `node "$CDKD_BIN" deploy --help`.)
#   RUNS         (default 3; the MEDIAN deploy time is reported)
#   WIDE_COUNT   (wide scenario: N of each resource type; default 8)
#
# Measures the single cold end-to-end deploy wall-time per tool. One-time setup
# (npm install / cdk bootstrap / terraform init) is done up-front, not timed.
#
# Completion definitions
# ----------------------
# Every row must compare tools whose definition of "done" matches. The tool
# names encode three definitions:
#
#   *-nowait    fire and forget: return without waiting for the scenario's
#               dominant resource to become usable
#   (plain)     each tool's own default
#   *-fullwait  wait for the resource to be fully in service
#
# A tool that has no distinct mode for a given scenario is reported as N/A with
# the reason, rather than silently omitted -- "cannot do this" must stay
# distinguishable from "was not measured".
#
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CDK_DIR="$ROOT/cdk"
RESULTS_DIR="$ROOT/results"

AWS_REGION="${AWS_REGION:-us-east-1}"; export AWS_REGION CDK_DEFAULT_REGION="$AWS_REGION"
CDKD_BIN="${CDKD_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/cdkd/dist/cli.js}"
RUNS="${RUNS:-3}"
TOOLS="${1:-cdkd,cdkd-nowait,cfn,tf}"
SCENARIO="${2:-webapp}"
export WIDE_COUNT="${WIDE_COUNT:-8}"

# Per-scenario Terraform var sets for the two non-default completion modes.
# An EMPTY set means the tool has no distinct mode here; TF_*_NA carries the
# reason printed in the results table.
declare -a TF_NOWAIT_VARS=() TF_FULLWAIT_VARS=()
TF_NOWAIT_NA=""; TF_FULLWAIT_NA=""; CDKD_FULLWAIT_NA=""

NO_SERVICE_NA="no ECS service in this stack; --full-wait is identical to the default"

case "$SCENARIO" in
  webapp)
    STACK="BenchWebApp"; TF_DIR="$ROOT/terraform"; TF_VARS=(-var "region=$AWS_REGION")
    TF_NOWAIT_NA="aws_nat_gateway has no wait opt-out"
    TF_FULLWAIT_NA="Terraform's default already waits for the NAT gateway"
    CDKD_FULLWAIT_NA="$NO_SERVICE_NA";;
  wide)
    STACK="BenchWide"; TF_DIR="$ROOT/terraform/wide"; TF_VARS=(-var "region=$AWS_REGION" -var "count_each=$WIDE_COUNT")
    TF_NOWAIT_NA="no resource in this stack has a stabilization wait"
    TF_FULLWAIT_NA="no resource in this stack has a stabilization wait"
    CDKD_FULLWAIT_NA="$NO_SERVICE_NA";;
  serverless)
    STACK="BenchServerless"; TF_DIR="$ROOT/terraform/serverless"; TF_VARS=(-var "region=$AWS_REGION")
    TF_NOWAIT_NA="no resource in this stack has a stabilization wait"
    TF_FULLWAIT_NA="no resource in this stack has a stabilization wait"
    CDKD_FULLWAIT_NA="$NO_SERVICE_NA";;
  cloudfront)
    STACK="BenchCloudFront"; TF_DIR="$ROOT/terraform/cloudfront"; TF_VARS=(-var "region=$AWS_REGION")
    TF_NOWAIT_VARS=(-var "wait_for_deployment=false")
    TF_FULLWAIT_NA="Terraform's default already waits for Deployed"
    CDKD_FULLWAIT_NA="$NO_SERVICE_NA";;
  ec2)
    STACK="BenchEc2"; TF_DIR="$ROOT/terraform/ec2"; TF_VARS=(-var "region=$AWS_REGION")
    TF_NOWAIT_NA="aws_instance has no wait opt-out"
    TF_FULLWAIT_NA="Terraform's default already waits for running"
    CDKD_FULLWAIT_NA="$NO_SERVICE_NA";;
  ecs)
    STACK="BenchEcs"; TF_DIR="$ROOT/terraform/ecs"; TF_VARS=(-var "region=$AWS_REGION")
    TF_NOWAIT_NA="aws_lb has no wait opt-out, and the service's fire-and-forget mode IS Terraform's default (see the tf row)"
    TF_FULLWAIT_VARS=(-var "wait_for_steady_state=true");;
  *) echo "unknown scenario: $SCENARIO (webapp|wide|serverless|cloudfront|ec2|ecs)"; exit 1;;
esac
# The non-default cdkd modes deploy DISTINCT twin stacks so their resource
# names never collide with the plain-cdkd stack's (SQS's 60s name-reuse
# cooldown, ELBv2's asynchronous delete).
NW_STACK="${STACK}Nw"
FW_STACK="${STACK}Fw"

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

declare -a CDKD_T=() NOWAIT_T=() FULLWAIT_T=() CFN_T=() TF_T=() TF_NOWAIT_T=() TF_FULLWAIT_T=()

setup(){
  phase "Preflight ($SCENARIO / tools=$TOOLS / RUNS=$RUNS)"
  aws sts get-caller-identity >/dev/null || { err "no creds"; exit 1; }
  ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"; export CDK_DEFAULT_ACCOUNT="$ACCOUNT"
  CDKD_VERSION="$(node "$CDKD_BIN" --version 2>/dev/null)"
  ok "account=$ACCOUNT region=$AWS_REGION cdkd=$CDKD_VERSION"
  # The default CDKD_BIN points at a sibling checkout's dist, which is usually
  # the last RELEASE rather than the tree under test. Record what was actually
  # measured so a results file can never be misattributed.
  ok "CDKD_BIN=$CDKD_BIN"
  CDKD_SHA="$( (cd "$(dirname "$CDKD_BIN")/.." && git rev-parse --short HEAD 2>/dev/null) || true )"
  CDKD_BRANCH="$( (cd "$(dirname "$CDKD_BIN")/.." && git rev-parse --abbrev-ref HEAD 2>/dev/null) || true )"
  [[ -n "$CDKD_SHA" ]] && ok "cdkd source: $CDKD_BRANCH @ $CDKD_SHA"
  [[ -d "$CDK_DIR/node_modules" ]] || (cd "$CDK_DIR" && npm install >/dev/null 2>&1)
  if has cdkd || has cdkd-nowait || has cdkd-fullwait || has cfn; then
    (cd "$CDK_DIR" && npx cdk bootstrap "aws://$ACCOUNT/$AWS_REGION" >/dev/null 2>&1) || warn "bootstrap non-zero"
  fi
  if has tf || has tf-nowait || has tf-fullwait; then
    command -v terraform >/dev/null || { err "terraform missing"; exit 1; }
    (cd "$TF_DIR" && terraform init -input=false >/dev/null 2>&1) || { err "tf init failed"; exit 1; }
  fi
  mkdir -p "$RESULTS_DIR"; echo ""
}

cdkd_destroy(){ (cd "$CDK_DIR" && node "$CDKD_BIN" destroy --app "node bin/app.ts" --force "${1:-$STACK}" >/dev/null 2>&1) || true; }
cfn_destroy(){  (cd "$CDK_DIR" && npx cdk destroy "$STACK" --force >/dev/null 2>&1) || true; }
tf_destroy(){   (cd "$TF_DIR" && terraform destroy -auto-approve -input=false "${TF_VARS[@]}" "$@" >/dev/null 2>&1) || true; }

time_cdkd(){ # $1 = extra flag (--no-wait / --full-wait / empty), $2 = log, $3 = stack (default $STACK)
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
time_tf(){ # $1 = log, $2.. = extra -var flags for the completion mode under test
  local log="$1"; shift
  tf_destroy "$@"
  local t=$(now_ms)
  (cd "$TF_DIR" && terraform apply -auto-approve -input=false "${TF_VARS[@]}" "$@" >"$log" 2>&1); local rc=$?
  local ms=$(( $(now_ms)-t )); tf_destroy "$@"
  [[ $rc -ne 0 ]] && { err "tf rc=$rc"; tail -12 "$log"; echo 0; return; }
  echo "$ms"
}

# row <label> <median> <reason-when-N/A> <all-run values...>
row(){
  local label="$1" med="$2" na_reason="$3"; shift 3
  # median() drops failed (zero) runs, so a zero median means EVERY run failed.
  # Keep that distinct from N/A: "the tool has no such mode" and "the tool has
  # the mode and it did not work" are different facts.
  if [[ "$med" -eq 0 ]]; then
    if [[ -n "$na_reason" ]]; then
      echo "| $label | N/A | $na_reason |"
    else
      echo "| $label | FAILED | every run returned non-zero; see results/*.log |"
    fi
    return
  fi
  local all=""; for x in "$@"; do all+="$(fmt "$x") "; done
  echo "| $label | $(fmt "$med") | $all |"
}

report(){
  local ts; ts="$(date '+%Y%m%d-%H%M%S')"; local out="$RESULTS_DIR/results-$SCENARIO-$ts.md"
  local m_cdkd m_nowait m_fullwait m_cfn m_tf m_tfnw m_tffw
  m_cdkd=$(median "${CDKD_T[@]:-0}"); m_nowait=$(median "${NOWAIT_T[@]:-0}"); m_fullwait=$(median "${FULLWAIT_T[@]:-0}")
  m_cfn=$(median "${CFN_T[@]:-0}"); m_tf=$(median "${TF_T[@]:-0}")
  m_tfnw=$(median "${TF_NOWAIT_T[@]:-0}"); m_tffw=$(median "${TF_FULLWAIT_T[@]:-0}")
  {
    echo "# Benchmark: $SCENARIO stack"
    echo ""
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S')  Region: $AWS_REGION  RUNS: $RUNS (median)"
    echo "- cdkd: $CDKD_VERSION  cdk: $(cd "$CDK_DIR" && npx cdk --version 2>/dev/null)  terraform: $(terraform --version 2>/dev/null | head -1)"
    echo "- cdkd binary: \`$CDKD_BIN\`${CDKD_SHA:+ (${CDKD_BRANCH} @ ${CDKD_SHA})}"
    [[ "$SCENARIO" == wide ]] && echo "- WIDE_COUNT: $WIDE_COUNT of each (S3/DDB/SQS/SNS/SSM/Logs)"
    echo ""
    echo "Metric = median cold end-to-end deploy wall-time (setup untimed)."
    echo "N/A = the tool has no such mode for this scenario (reason in the last column),"
    echo "not \"was not measured\"."
    echo ""
    echo "| Tool | Deploy (median) | all runs |"
    echo "|---|---|---|"
    has cdkd          && row "cdkd"                     "$m_cdkd"     ""                   "${CDKD_T[@]}"
    has cdkd-nowait   && row "cdkd --no-wait"           "$m_nowait"   ""                   "${NOWAIT_T[@]}"
    has cdkd-fullwait && row "cdkd --full-wait"         "$m_fullwait" "$CDKD_FULLWAIT_NA"  "${FULLWAIT_T[@]}"
    has cfn           && row "CloudFormation"           "$m_cfn"      ""                   "${CFN_T[@]}"
    has tf            && row "Terraform"                "$m_tf"       ""                   "${TF_T[@]}"
    has tf-nowait     && row "Terraform (no wait)"      "$m_tfnw"     "$TF_NOWAIT_NA"      "${TF_NOWAIT_T[@]}"
    has tf-fullwait   && row "Terraform (wait for healthy)" "$m_tffw" "$TF_FULLWAIT_NA"    "${TF_FULLWAIT_T[@]}"
  } | tee "$out"
  echo ""; info "saved: $out"
}

main(){
  setup
  for ((i=1;i<=RUNS;i++)); do
    info "=== run $i/$RUNS ($SCENARIO) ==="
    has cdkd          && { phase "cdkd (run $i)";               CDKD_T+=("$(time_cdkd '' "$RESULTS_DIR/cdkd-$SCENARIO.log")");                       ok "cdkd $(fmt ${CDKD_T[-1]})"; }
    has cdkd-nowait   && { phase "cdkd --no-wait (run $i)";     NOWAIT_T+=("$(time_cdkd '--no-wait' "$RESULTS_DIR/nowait-$SCENARIO.log" "$NW_STACK")"); ok "cdkd --no-wait $(fmt ${NOWAIT_T[-1]})"; }
    if has cdkd-fullwait; then
      if [[ -n "$CDKD_FULLWAIT_NA" ]]; then
        [[ $i -eq 1 ]] && warn "cdkd --full-wait: N/A for $SCENARIO ($CDKD_FULLWAIT_NA)"
      else
        phase "cdkd --full-wait (run $i)"; FULLWAIT_T+=("$(time_cdkd '--full-wait' "$RESULTS_DIR/fullwait-$SCENARIO.log" "$FW_STACK")"); ok "cdkd --full-wait $(fmt ${FULLWAIT_T[-1]})"
      fi
    fi
    has cfn           && { phase "CloudFormation (run $i)";     CFN_T+=("$(time_cfn "$RESULTS_DIR/cfn-$SCENARIO.log")");                             ok "cfn $(fmt ${CFN_T[-1]})"; }
    has tf            && { phase "Terraform (run $i)";          TF_T+=("$(time_tf "$RESULTS_DIR/tf-$SCENARIO.log")");                                ok "tf $(fmt ${TF_T[-1]})"; }
    if has tf-nowait; then
      if [[ ${#TF_NOWAIT_VARS[@]} -eq 0 ]]; then
        [[ $i -eq 1 ]] && warn "Terraform (no wait): N/A for $SCENARIO ($TF_NOWAIT_NA)"
      else
        phase "Terraform no-wait (run $i)"; TF_NOWAIT_T+=("$(time_tf "$RESULTS_DIR/tf-nowait-$SCENARIO.log" "${TF_NOWAIT_VARS[@]}")"); ok "tf no-wait $(fmt ${TF_NOWAIT_T[-1]})"
      fi
    fi
    if has tf-fullwait; then
      if [[ ${#TF_FULLWAIT_VARS[@]} -eq 0 ]]; then
        [[ $i -eq 1 ]] && warn "Terraform (wait for healthy): N/A for $SCENARIO ($TF_FULLWAIT_NA)"
      else
        phase "Terraform wait-for-healthy (run $i)"; TF_FULLWAIT_T+=("$(time_tf "$RESULTS_DIR/tf-fullwait-$SCENARIO.log" "${TF_FULLWAIT_VARS[@]}")"); ok "tf wait-for-healthy $(fmt ${TF_FULLWAIT_T[-1]})"
      fi
    fi
  done
  report
}
main
