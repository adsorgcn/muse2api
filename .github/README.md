# muse2api · iLang 一键版

把 muse.ai 网页端的对话、生图、生视频变成 OpenAI 兼容接口，装在你自己的服务器上。多个 muse.ai 号组成号池轮着用，一个号额度用完自动换下一个。

## 一句话安装：交给你的 AI

在 Claude Code、Codex、Cursor、Gemini CLI、DeepSeek Harness、Grok Bot 这类能跑命令的 AI 里贴这一句：

```text
帮我部署 muse2api，照 https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.md 做。
```

它先弹一张卡片让你勾这次装哪些：

```text
1. muse2api 本体：号池和 OpenAI 兼容接口
2. 域名加 https：用你自己的域名，自动签证书
3. 中转站 New API：连接模型、应用与 Agent 的 AI 网关
   勾了 3 再问：注册（开放 / 只由你建账号）、计价（免费 / 按次定价）
```

然后问你服务器 IP，请你自己输一次 root 密码，装好后弹出一个干净的 Chrome 窗口让你登录 muse.ai，号就进了号池。以后想加哪一项，再贴一遍那句话勾上就行。要加号，新开一个对话贴：

```text
导号，照 https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.md 的 M3 做。
```

国内打不开 raw.githubusercontent.com 的，把地址换成 `https://cdn.jsdelivr.net/gh/adsorgcn/muse2api@main/install.md`。

## 一行命令安装：自己上服务器

Ubuntu 或 Debian，用 root 跑：

```bash
curl -fsSL https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.sh | bash
```

有域名就带上它（先把 A 记录指到服务器；解析在 Cloudflare 的只开 DNS，不开橙色代理；有 AAAA 记录的要指向这台或删掉）：

```bash
curl -fsSL https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.sh | bash -s -- --domain api.example.com
```

- 重跑同一行就是升级，密钥和号池都保留，旧镜像会清掉。
- 带域名时，先在 IP 上装好，再装 nginx、签 Let's Encrypt 证书（不填邮箱），证书签下来才切到 https。签不下来服务照旧在 `http://IP:18610` 能用，脚本会告诉你原因，多半是服务商安全组没放行 80 和 443。
- 80/443 被宝塔、1Panel 这类面板占着时，脚本把服务装在 IP 上，最后一行是 `MUSE2API_INSTALL_PENDING_PROXY`。照它的提示在面板里给域名建站、反代到 `http://127.0.0.1:18610`，再跑一次同一行就切到 https。80/443 被 Docker 容器或别的程序占着时，脚本在改动任何东西之前就停下。
- 不碰 sshd、root 登录、密码、钥匙和防火墙规则，不跑 `apt upgrade`。新装 Docker 时 Docker 会加自己的 iptables 规则；没域名时 18610 由 Docker 发布，ufw 管不到它，外面连不上就去服务商安全组放行。
- 中转站：`--relay new-api --relay-register open|closed --relay-price free|chat=0.01,image=0.05,video=0.5`（价格是每次多少美元），见下面「中转站」一节。
- 其他选项：`--no-domain` 换回 IP、`--no-relay` 停掉中转站、`--ip` 手动给公网 IPv4、`--ref` 指定版本、`--dir` 换安装目录、`--force` 跳过内存和磁盘检查。
- 最后一行是 `MUSE2API_INSTALL_OK`、`MUSE2API_INSTALL_PENDING_PROXY` 或 `[muse2api] ERROR:` 三种之一。

## 导号进号池

装好后，在你自己电脑的 Chrome 上二选一：

- **Python 助手**：`scp root@你的IP:/opt/muse2api/tools/get_muse_cookie.py .` 拿到脚本，设好环境变量 `MUSE2API_BASE`、`MUSE2API_KEY` 后运行 `python get_muse_cookie.py --label 号1`，在弹出的干净窗口里登录（先填邮箱，再填邮件里的验证码；脚本说导入成功之前别关窗口）。
- **扩展**：`scp -r root@你的IP:/opt/muse2api/extension .`（或下载 `你的地址/admin/extension`），在 `chrome://extensions` 打开开发者模式，加载这个文件夹。登录 muse.ai 后点扩展图标，填地址、密钥、标签，点「读取并导入」。

没有域名时，从 `http://` 地址下载的东西可能被人在路上改掉，用 `scp` 更稳。每导一个号，在管理页点一次「测试」。

## 密钥

- 看密钥：在服务器上 `grep ^MUSE2API_KEY= /opt/muse2api/.env`
- 管理页：`你的地址/admin?key=你的密钥`
- 换密钥：改 `/opt/muse2api/.env` 里那一行，再跑一次安装命令，然后在管理页的密钥框里填新密钥保存（浏览器会记着旧的）。管理页上的「重新生成」只撑到容器下一次重启，之后旧密钥又生效。
- 重跑时 `.env` 里已有的密钥原样保留（带引号、`export` 写法、自定义格式都认）；只有上游示例里那个公开的占位密钥 `m2a_your_secret_admin_key_here` 会被换掉，脚本会醒目提示，旧 `.env` 备份在旁边。

## 调用

```bash
curl 你的地址/v1/chat/completions \
  -H "Authorization: Bearer 你的密钥" -H "Content-Type: application/json" \
  -d '{"model":"muse-spark","stream":true,"messages":[{"role":"user","content":"你好"}]}'
```

模型：`muse-spark` 对话，`muse-image` 生图，`muse-video` 生视频；`gpt-4o` 一类常见名字也会自动对上。生图、生视频是长任务，用 `/v1/images/tasks`、`/v1/videos` 提交后轮询结果。

## 中转站（New API）

[New API](https://github.com/QuantumNous/new-api) 官方的说法：面向应用、Agent 和团队的自托管 AI 网关，在同一套控制台中管理渠道、访问权限、用量与成本。

- 装在 `/opt/new-api`，跟 muse2api 用同一个域名：`/admin` 和 `/v1/media/` 还是 muse2api，其余交给 New API。安装会把 muse2api 加成它的一个渠道。
- 管理员是 `root`，密码在服务器上：`grep ^password= /opt/new-api/.admin`。在网页里改了密码，把这个文件也改了，不然以后重跑更新不了 New API。
- 登录后给自己和亲友建令牌，大家拿令牌和 `https://你的域名/v1` 来用；muse2api 自己的密钥只用于导号和它的管理页。
- 注册和计价是你装的时候选的，以后重跑带上 `--relay-register` 或 `--relay-price` 就能改。
- 收款：New API 的说明里写着，开收款、充值、兑换码之前要管理员先确认它的合规条款，收款渠道在它的设置里配。
- 不想要了：`--no-relay` 停掉它，数据留在 `/opt/new-api`。

## 要求与实测

- 服务器：Ubuntu 或 Debian，有公网 IPv4，内存至少 900 MiB 且内存加 swap 至少 1700 MiB，盘剩 5G 起，能打开 muse.ai。
- 2026-11-23 在一台已装 Docker 的 Ubuntu 24.04 x86_64 上实测：全新安装、原地升级（第二次 3 秒）、占位密钥替换、自定义密钥保留、防并发、域名解析不对或 AAAA 指错时不动手、80 被 Docker 容器占着时不动手、证书签不下来时不切换、签下来后切到 https、切回 IP。工程书里的原样命令和验收在那台机器上跑通；上一版工程书由 Grok Bot 整本跑通。
- 没测过：没装 Docker 的机器（会从 Docker 官方源装）、Debian、arm64、面板占着 80/443 的机器、只有 IPv6 的机器、自动更新正占着 apt 锁的新机器（脚本会等最多 10 分钟）。
- 自己手搭过、用自己的 https 前端的实例：重跑时脚本不接管你的前端，`MUSE2API_PUBLIC_BASE` 和端口绑定保持原样；想让脚本管 https 就带 `--domain`。

## 这个仓库

fork 自 MUSE2API（MIT，原作者 MUSE2API Authors）。原项目的代码一行没改，本仓库只加了 `install.sh`、`install.md` 和给 AI 读的说明（`AGENTS.md`、`CLAUDE.md`、`GEMINI.md`）。上游出新版，先在测试机上跑通再同步进来。

## English

muse2api serves the chat, image and video generation of the muse.ai web app as an OpenAI-compatible API on your own server, with a pool of your own muse.ai accounts.

- Ask your agent: `Deploy muse2api for me by following https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.md`
- Or run as root on Ubuntu/Debian with a public IPv4: `curl -fsSL https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.sh | bash`. Add `-s -- --domain your.domain` for https: the service is installed on plain IP first and switched only after nginx and the certificate work. Re-run to upgrade; your key and accounts are kept. It never changes sshd, logins or firewall rules (a fresh Docker install adds Docker's own iptables rules, and without a domain port 18610 is published past ufw).
- Import accounts from your own Chrome with `tools/get_muse_cookie.py` or the `extension/` folder (fetch both with `scp` from `/opt/muse2api`).
- Optional relay station: `--relay new-api --relay-register open|closed --relay-price free|chat=X,image=Y,video=Z` puts [New API](https://github.com/QuantumNous/new-api) on the same domain and adds muse2api as its channel; `--no-relay` stops it.

Forked from MUSE2API (MIT, MUSE2API Authors); upstream code is unchanged.

---

出品 iLang · https://ilang.ai · 更多工程书 https://dsh.ilang.guide/
