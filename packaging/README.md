# 分发与发布

本目录放**面向他人分发**的物料；本机自用只需 `./build-app.sh`。

```
packaging/Casks/laomac.rb   # Homebrew cask 定义 (需复制到 tap 仓库才生效)
release.sh                  # 通用编译 → dmg/zip → gh release 发布 (本地或 CI 同一入口)
install.sh                  # 用户侧一行安装/卸载脚本 (随 main 分支 raw URL 分发)
.github/workflows/release.yml  # 推 tag 自动触发 release.sh
```

## 1. 手动发布 (本机)

```bash
./release.sh v1.2 -n     # dry-run: 只出包不上传, 先看产物
./release.sh v1.2        # 正式: 编译 → 打 tag → 建 Release → 上传资产
```

产物资产 (`dist/`)：

| 文件 | 用途 |
|---|---|
| `Laomac-<ver>.dmg` | 人肉下载拖拽安装（含 Applications 快捷方式） |
| `Laomac-<ver>.zip` | brew cask / 脚本安装 |
| `Laomac-latest.zip` / `.dmg` / `.sha256` | **固定 URL**，`releases/latest/download/...` 永远指向最新版 |
| `Laomac-<ver>.sha256` | install.sh 下载后校验完整性 |

`release.sh` 会把版本号写回根目录 `VERSION`，并在 Release 说明里自动列出上一个 tag 以来的提交。

## 2. CI 自动发布

推 tag 即触发（`.github/workflows/release.yml`，`macos-14` runner）：

```bash
git tag -a v1.2 -m "Laomac 1.2" && git push origin v1.2
```

CI 用 workflow 自带的 `GITHUB_TOKEN` 建 Release，不需要额外 secret。
注意 CI 出包是 **ad-hoc 签名**（`signing/` 私钥不入库），用户首次打开需右键"打开"；
本机 `./release.sh` 会走本地自签证书，TCC 授权更稳定。

## 3. 用户侧安装

```bash
# 一行安装 (校验 sha256 → /Applications → 去 quarantine → 装 SMC 组件)
curl -fsSL https://raw.githubusercontent.com/gsxuan/laomac/main/install.sh | bash

# 卸载
curl -fsSL https://raw.githubusercontent.com/gsxuan/laomac/main/install.sh | bash -s -- --uninstall
```

## 4. Homebrew tap (可选)

tap 必须是**独立仓库**，命名 `homebrew-<名字>`：

```bash
gh repo create gsxuan/homebrew-tap --public --description "Homebrew casks"
git clone https://github.com/gsxuan/homebrew-tap && cd homebrew-tap
mkdir -p Casks
cp /path/to/laomac/packaging/Casks/laomac.rb Casks/
git add . && git commit -m "add laomac cask" && git push
```

之后用户：

```bash
brew tap gsxuan/tap
brew install --cask laomac
```

发版后要做的维护：若 cask 用「方式 B 固定哈希」，需把新 `shasum -a 256 dist/Laomac-<ver>.zip`
结果回填进 tap 仓库的 `laomac.rb`（并更新 `version`）；用默认的「方式 A `:no_check` + latest URL」
则一行都不用改，代价是不校验哈希。

本地校验 cask 语法：

```bash
brew tap --repair
brew audit --cask --strict Casks/laomac.rb   # 需在 tap 仓库路径下
```

## 5. 关于 Gatekeeper

未花 $99/年 做 Developer ID + 公证时，下载来的 app 一定带隔离标记，三种规避路径：
`install.sh` 自动 `xattr -dr`、cask 的 `postflight` 自动去标记、手动右键"打开"。
要在他人机器上完全无提示，只能上 Apple 开发者证书，脚本里预留的位置是
`build-app.sh` 的签名段（把 `IDENTITY` 换成 `Developer ID Application: ...` 并加 `xcrun notarytool`）。
