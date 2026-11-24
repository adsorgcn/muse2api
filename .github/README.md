# muse2api · iLang 一键版

把 muse.ai 网页端的对话、生图、生视频变成 OpenAI 兼容接口，装在你自己的服务器上。多个 muse.ai 号组成号池轮着用，一个号额度用完自动换下一个。

## 一句话安装：交给你的 AI

在 Claude Code、Codex、Cursor、Gemini CLI、DeepSeek Harness、Grok Bot 这类能跑命令的 AI 里贴这一句：

```text
帮我部署 muse2api，照 https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.md 做。
```

它会问你服务器 IP，请你自己输一次 root 密码，装好后弹出一个干净的 Chrome 窗口让你登录 muse.ai，号就进了号池。以后说一句「导号」就能再加号。

国内打不开 raw.githubusercontent.com 的，把地址换成 `https://cdn.jsdelivr.net/gh/adsorgcn/muse2api@main/install.md`。

## 一行命令安装：自己上服务器

Ubuntu 或 Debian，用 root 跑：

```bash
curl -fsSL https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.sh | bash
```

有域名就带上它（先把 A 记录指到服务器；解析在 Cloudflare 的只开 DNS，不开橙色代理）：

```bash
curl -fsSL https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.sh | bash -s -- --domain api.example.com
```

- 重跑同一行就是升级，密钥和号池都保留。
- 不碰 sshd、root 登录、密码、钥匙和防火墙，不跑 `apt upgrade`。
- 缺 Docker 会从 Docker 官方源装；有域名会装 nginx 并签 Let's Encrypt 证书（不填邮箱）。
- 其他选项：`--no-domain` 换回 IP、`--ip` 手动给公网 IP、`--ref` 指定版本、`--dir` 换安装目录。

## 导号进号池

装好后，在你自己电脑的 Chrome 上二选一：

- **扩展**：下载 `你的地址/admin/extension`，解压，在 `chrome://extensions` 打开开发者模式，加载已解压的扩展程序。登录 muse.ai 后点扩展图标，填地址、密钥、标签，点「读取并导入」。
- **Python 助手**：下载 `你的地址/admin/cookie-helper?download=1` 存成 `get_muse_cookie.py`，设好环境变量 `MUSE2API_BASE`、`MUSE2API_KEY` 后运行 `python get_muse_cookie.py --label 号1`，在弹出的干净窗口里登录（先填邮箱，再填邮件里的验证码）。

每导一个号，在管理页点一次「测试」。

- 密钥：在服务器上 `grep ^MUSE2API_KEY= /opt/muse2api/.env`
- 管理页：`你的地址/admin?key=你的密钥`

## 调用

```bash
curl 你的地址/v1/chat/completions \
  -H "Authorization: Bearer 你的密钥" -H "Content-Type: application/json" \
  -d '{"model":"muse-spark","stream":true,"messages":[{"role":"user","content":"你好"}]}'
```

模型：`muse-spark` 对话，`muse-image` 生图，`muse-video` 生视频；`gpt-4o` 一类常见名字也会自动对上。生图、生视频是长任务，用 `/v1/images/tasks`、`/v1/videos` 提交后轮询结果。

## 要求与实测

- 服务器：Ubuntu 或 Debian，内存 2G 起，盘剩 5G 起，能打开 muse.ai。
- 2026-11-23 实测：Ubuntu 24.04 x86_64 上全新安装、原地升级、防重复安装、域名加 https、切回 IP 都跑通；同一套部署和导号由 Grok Bot 照工程书整本跑通。
- 没测过：Debian、arm64、宝塔等面板占着 80/443 的机器（脚本会停在证书那步，并告诉你在面板里怎么反代）。

## 这个仓库

fork 自 MUSE2API（MIT，原作者 MUSE2API Authors）。原项目的代码一行没改，本仓库只加了 `install.sh`、`install.md` 和给 AI 读的说明（`AGENTS.md`、`CLAUDE.md`、`GEMINI.md`）。上游出新版，先在测试机上跑通再同步进来。

## English

muse2api serves the chat, image and video generation of the muse.ai web app as an OpenAI-compatible API on your own server, with a pool of your own muse.ai accounts.

- Ask your agent: `Deploy muse2api for me by following https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.md`
- Or run as root on Ubuntu/Debian: `curl -fsSL https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.sh | bash` (add `-s -- --domain your.domain` for https). Re-run to upgrade; your key and accounts are kept. It never touches sshd, logins or the firewall.
- Import accounts from your own Chrome with the extension at `<base>/admin/extension` or the helper at `<base>/admin/cookie-helper?download=1`.

Forked from MUSE2API (MIT, MUSE2API Authors); upstream code is unchanged.

---

出品 iLang · https://ilang.ai · 更多工程书 https://dsh.ilang.guide/
