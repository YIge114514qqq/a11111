#!/bin/bash
# 看最近一次 CI 的结果。不打印 token。
export GH_TOKEN=$(tr -d ' \r\n' < LOCAL-TOKEN.txt)
REPO="YIge114514qqq/a11111"

if [ -z "$GH_TOKEN" ]; then echo "找不到 LOCAL-TOKEN.txt"; exit 1; fi

RUN=$(gh run list --repo "$REPO" --limit 1 --json databaseId,status,conclusion,headSha,displayTitle \
      --jq '.[0] | "\(.databaseId)|\(.status)|\(.conclusion)|\(.headSha[0:7])|\(.displayTitle)"')
ID=$(echo "$RUN" | cut -d'|' -f1)
ST=$(echo "$RUN" | cut -d'|' -f2)
CN=$(echo "$RUN" | cut -d'|' -f3)
SH=$(echo "$RUN" | cut -d'|' -f4)
TI=$(echo "$RUN" | cut -d'|' -f5)

echo "commit   $SH"
echo "标题     $TI"
echo "状态     $ST / ${CN:-进行中}"
echo "链接     https://github.com/$REPO/actions/runs/$ID"
echo "-----------------------------------------------"

if [ "$ST" != "completed" ]; then
  echo "还没跑完。等 3 分钟再执行 ./check-ci.sh"
  exit 0
fi

LOG=$(gh run view "$ID" --repo "$REPO" --log 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')

echo "【测试与构建】"
echo "$LOG" | grep -aE "PASS:[ ]+[0-9]+ model checks|PASS:[ ]+tutor chain|PASS:[ ]+tutor log|\*\* BUILD (SUCCEEDED|FAILED)" \
  | sed -E 's/^[^\t]*\t[^\t]*\t[0-9T:.Z-]+ //' | sed 's/^[[:space:]]*//'

echo "$LOG" | grep -aq "OK: plist 关键项齐全" && echo "PASS: plist 关键项齐全" || echo "FAIL: plist 未通过"

ERRS=$(echo "$LOG" | grep -aE "error: |FAIL: |Testing failed|\*\* BUILD FAILED" | grep -av "ERROR: App 进程已退出" | head -25)
if [ -n "$ERRS" ]; then
  echo
  echo "【报错】"
  echo "$ERRS" | sed -E 's/^[^\t]*\t[^\t]*\t[0-9T:.Z-]+ //' | sed 's/^[[:space:]]*//'
fi

echo
case "$CN" in
  success) echo ">>> 通过" ;;
  cancelled) echo ">>> 被取消（不是失败）。重新执行: gh run rerun $ID --repo $REPO" ;;
  *) echo ">>> 失败，看上面的【报错】" ;;
esac
