#!/bin/zsh

set -euo pipefail

setup_root=${0:A:h}
bundle=${setup_root:h:h:h}
codexbar_user_home=${HOME:?User home is unavailable}
allowed_roots=(/Applications "$codexbar_user_home/Applications")
if [[ -n ${CODEXBAR_APPLICATIONS_ROOT:-} ]]; then
    allowed_roots=("$CODEXBAR_APPLICATIONS_ROOT")
fi

installed=false
for candidate_root in "${allowed_roots[@]}"; do
    if [[ "$candidate_root" == /* && "${candidate_root:a}" != / && ! -L "$candidate_root" \
          && "${bundle:h}" == "${candidate_root:A}" ]]; then
        installed=true
    fi
done
if [[ "$installed" != true || "$bundle:t" != *.app \
      || "$setup_root" != "$bundle/Contents/Resources/HookSetup" ]]; then
    print -u2 "请先把 CodexBar.app 移到 /Applications 或 ~/Applications，再从应用菜单安装任务连接。"
    print -u2 "Downloads、dist、App Translocation 或 Applications 的子目录不适合作为任务连接安装位置。"
    exit 64
fi

# The current installed app owns this connection, regardless of shell preferences.
export CODEXBAR_HOOK_EXECUTABLE="$bundle/Contents/Helpers/codexbar-hook"
/bin/zsh "$setup_root/install-hooks"
print "任务连接已安装或更新。请重新加载 VS Code，在 Codex Settings > Hooks 中检查并信任这些定义。"
print "完成后可以关闭此终端窗口。"
