#!/usr/bin/env bash
# Offline cloud validation: public tool downloads, provider schemas, mock plans.
# There is intentionally no real plan/apply or Azure credential acquisition here.
set -euo pipefail

task_module_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -s):$(uname -m)" in
  Darwin:arm64)
    task_platform=darwin_arm64
    task_terraform_sha=f210110c5698b94d803a7a63cdb0251b5455c150841478808e2bbb343f95ed68
    task_tflint_sha=2496e9cb3d24992d553b45e7c87a0fdc9449ca975233876247a9bfeda857e6c0
    ;;
  Darwin:x86_64)
    task_platform=darwin_amd64
    task_terraform_sha=e2e812e783771159bf758fd4e55d6dc9bb08f63e2af2c63d212721807a02c5dc
    task_tflint_sha=0f3a9fd17526014646a2dfc3f9122f7b4161abe3d6b0f0f03f9014483ddf4d19
    ;;
  Linux:x86_64)
    task_platform=linux_amd64
    task_terraform_sha=d25ce7b6902013ad905db3d2eab0be4cd905887fe88b81a6171b8d5503c31f3d
    task_tflint_sha=cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537
    ;;
  Linux:aarch64|Linux:arm64)
    task_platform=linux_arm64
    task_terraform_sha=8891e9dcedc9e3b8950bc6af9d4d8af1f4cfade3062f53b9dc403a89f6ce8c9c
    task_tflint_sha=560da89aacf59389d4eb029730dd5b109b7288096c32f2726a0d9e783a5ea8eb
    ;;
  *) printf '%s\n' 'This validator supports macOS/Linux AMD64 and ARM64.' >&2; exit 1 ;;
esac

umask 077
task_scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/cosmos-sync-tf-verify.XXXXXXXX")"
trap 'rm -rf -- "$task_scratch_dir"' EXIT

task_unpack_verified() {
  local task_url="$1" task_sha="$2" task_tool="$3"
  curl --disable --location --fail --silent --show-error --proto '=https' --proto-redir '=https' \
    --max-time 120 "$task_url" -o "$task_scratch_dir/$task_tool.zip"
  python3 -I - "$task_scratch_dir/$task_tool.zip" "$task_sha" "$task_scratch_dir/$task_tool" <<'PY'
import hashlib
from pathlib import Path
import sys
import zipfile

archive, expected, destination = sys.argv[1:]
if hashlib.sha256(Path(archive).read_bytes()).hexdigest() != expected:
    raise SystemExit("Pinned official tool archive checksum mismatch")
target = Path(destination)
with zipfile.ZipFile(archive) as source:
    target.write_bytes(source.read(target.name))
target.chmod(0o700)
PY
}

task_unpack_verified \
  "https://releases.hashicorp.com/terraform/1.15.8/terraform_1.15.8_${task_platform}.zip" \
  "$task_terraform_sha" terraform
task_unpack_verified \
  "https://github.com/terraform-linters/tflint/releases/download/v0.64.0/tflint_${task_platform}.zip" \
  "$task_tflint_sha" tflint

# Avoid ambient Terraform CLI argument/backend/provider overrides. Mock providers
# never authenticate, and validate loads schemas without configuring Azure.
unset TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_fmt TF_CLI_ARGS_validate TF_CLI_ARGS_test
unset TF_REATTACH_PROVIDERS TF_PLUGIN_CACHE_DIR TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE
unset TF_LOG TF_LOG_PATH TF_LOG_CORE TF_LOG_PROVIDER TFLINT_CONFIG_FILE
export TF_CLI_CONFIG_FILE="$task_scratch_dir/terraform.rc"
export TF_DATA_DIR="$task_scratch_dir/terraform-data"
export TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1
printf '%s\n' 'disable_checkpoint = true' > "$TF_CLI_CONFIG_FILE"
"$task_scratch_dir/terraform" -chdir="$task_module_dir" fmt -check -recursive
"$task_scratch_dir/terraform" -chdir="$task_module_dir" init -backend=false -input=false -lockfile=readonly
"$task_scratch_dir/terraform" -chdir="$task_module_dir" validate -no-color
"$task_scratch_dir/terraform" -chdir="$task_module_dir" test -no-color
"$task_scratch_dir/tflint" --chdir="$task_module_dir" --config="$task_module_dir/.tflint.hcl" --format=compact
printf '%s\n' 'ACA Terraform: fmt, locked init, validate, mock plan tests and TFLint passed; no Azure apply or live acceptance.'
