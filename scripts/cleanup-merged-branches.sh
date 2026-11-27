#!/usr/bin/env bash
# 清理 CodeFlowOS：删除组织仓库中已合并超过宽限期（默认 72 小时）的个人 fork 分支。
#
# 用法:
#   scripts/cleanup-merged-branches.sh            # dry-run，只列出将要删除的分支
#   scripts/cleanup-merged-branches.sh --apply    # 实际执行删除
#
# 跳过规则：fork 默认分支、受保护分支、仍有未关闭 PR 的分支、合并后又有新提交的分支。
set -euo pipefail

ORG="CS-CodeFlow/CodeFlowOS"
FORK="MCB-SMART-BOY/CodeFlowOS"
GRACE_HOURS="${GRACE_HOURS:-72}"

APPLY=0
if [[ "${1:-}" == "--apply" ]]; then APPLY=1; fi

# ISO8601 时间戳，字典序比较即可
cutoff=$(date -u -d "-${GRACE_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)

default_branch=$(gh api "repos/${FORK}" --jq .default_branch)

# 已合并、head 来自本 fork、且合并时间早于 cutoff 的 PR：number \t branch \t head_sha
candidates=$(gh api --paginate "repos/${ORG}/pulls?state=closed&per_page=100" \
  --jq ".[] | select(.merged_at != null and .head.repo.full_name == \"${FORK}\" and .merged_at < \"${cutoff}\") | [.number, .head.ref, .head.sha] | @tsv")

if [[ -z "$candidates" ]]; then
  echo "没有合并超过 ${GRACE_HOURS} 小时的 fork 分支。"
  exit 0
fi

while IFS=$'\t' read -r pr branch sha; do
  if [[ "$branch" == "$default_branch" ]]; then continue; fi

  # 该 head 分支仍有未关闭的 PR → 跳过
  open_count=$(gh pr list --repo "$ORG" --state open --head "${FORK}:${branch}" --json number --jq 'length')
  if [[ "$open_count" != "0" ]]; then
    echo "保留 ${branch}：PR #${pr} 之后仍有未关闭的 PR。"
    continue
  fi

  enc=${branch//\//%2F}
  info=$(gh api "repos/${FORK}/branches/${enc}" --jq '[.protected, .commit.sha] | @tsv' 2>/dev/null) || {
    echo "跳过 ${branch}：分支已不存在。"
    continue
  }
  protected=${info%%$'\t'*}
  current_sha=${info##*$'\t'}

  if [[ "$protected" == "true" ]]; then
    echo "保留 ${branch}：受保护分支。"
    continue
  fi
  if [[ "$current_sha" != "$sha" ]]; then
    echo "保留 ${branch}：合并后有新提交（${sha:0:7} → ${current_sha:0:7}）。"
    continue
  fi

  if [[ "$APPLY" == "1" ]]; then
    gh api -X DELETE "repos/${FORK}/git/refs/heads/${branch}" >/dev/null
    echo "已删除 ${branch}（PR #${pr}，合并超过 ${GRACE_HOURS} 小时）。"
  else
    echo "[dry-run] 将删除 ${branch}（PR #${pr}，合并超过 ${GRACE_HOURS} 小时）。"
  fi
done <<< "$candidates"
