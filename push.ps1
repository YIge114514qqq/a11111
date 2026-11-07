# 一键推送到 GitHub
# 用法：  .\push.ps1 https://github.com/你的用户名/lecturebuddy.git
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoUrl
)

$ErrorActionPreference = "Stop"
$env:Path = "C:\Program Files\Git\cmd;" + $env:Path
Set-Location $PSScriptRoot

Write-Host "==> 当前目录: $PSScriptRoot"

$existing = git remote get-url origin 2>$null
if ($LASTEXITCODE -eq 0) {
    git remote set-url origin $RepoUrl
    Write-Host "==> 已更新远程地址: $RepoUrl"
} else {
    git remote add origin $RepoUrl
    Write-Host "==> 已添加远程地址: $RepoUrl"
}

Write-Host "==> 推送到 main ..."
git push -u origin main
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "推送失败。常见原因："
    Write-Host "  1. 仓库地址写错了（要 .git 结尾的那个）"
    Write-Host "  2. 浏览器弹窗登录被关掉了 —— 重新运行本脚本，在弹出的窗口里登录 GitHub"
    Write-Host "  3. 仓库里已经有文件 —— 在 GitHub 上建仓库时不要勾选 README / .gitignore / license"
    exit 1
}

Write-Host ""
Write-Host "推送成功！接下来："
Write-Host "  打开 $($RepoUrl -replace '\.git$','')/actions"
Write-Host "  点左边的 Build unsigned IPA -> Run workflow -> 绿色按钮"