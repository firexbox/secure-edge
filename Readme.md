这套程序为你打造了一个"阅后即焚、密码上锁"的浏览器安全沙箱，所有的浏览记录、书签和 Cookie 都会被锁在极高强度的加密容器中。

---

## 🛡️ Secure Edge 完整使用指南

### 一、 核心功能概述
Secure Edge 是一个基于本地脚本驱动的隐私保护工具，它主要做三件事：
1. **启动拦截**：没有正确的密码，任何人都无法通过该脚本启动你的专属 Edge 环境。
2. **数据加密**：使用军工级加密工具（VeraCrypt）挂载加密容器（`UserData.hc`）。浏览器一关，加密盘瞬间消失，不留痕迹。
3. **三模式存储**：根据你的加密盘大小和性能需求，灵活选择数据存储策略。

---

### 二、 首次运行配置（只需做一次）

#### 步骤 1：选择存储模式
```cmd
.\se.bat --setup-mode
```
首次运行 `se.bat` 会自动弹出模式选择菜单。你也可以随时用 `--setup-mode` 重新选择。

| 模式 | 说明 | 适用场景 |
|---|---|---|
| **[1] 全加密** | 所有数据都在加密盘 Y: 上 | 加密盘空间充足，最高安全 |
| **[2] 加密根+本地缓存**（推荐） | 核心数据在加密盘，大缓存（>100MB）放在本地 | 安全与空间的平衡 |
| **[3] 本地根+隐私加密** | 数据在本地，仅隐私敏感文件在加密盘 | 加密盘空间小，性能优先 |

> 选择后写入 `config_edge\mode.cfg`，后续启动不再询问。

#### 步骤 2：设置浏览器启动密码
```cmd
.\se.bat --setup-password
```
按提示输入并确认密码。密码哈希保存在 `config_edge\password_edge.enc`。

#### 步骤 3：创建加密容器
```cmd
.\se.bat --setup-encryption
```
- 脚本会自动加载加密模块。如未安装 VeraCrypt，请从 [veracrypt.io](https://veracrypt.io/zh-cn/Downloads.html) 下载便携版，解压到 `secure-edge\veracrypt\`，并将 `.exe` 文件名中的 `-x64` 去掉（如 `VeraCrypt.exe`、`VeraCrypt Format.exe`）。
- **容量建议**：
  - 模式 [1] 全加密：建议 500MB–1GB
  - 模式 [2] 加密根+本地缓存：建议 200–500MB（缓存不放加密盘）
  - 模式 [3] 本地根+隐私加密：建议 100–200MB（仅存放隐私文件）
- 如需扩容：启动 `VeraCrypt.exe` → 工具 → 加密卷扩展向导。
- **💡 建议：加密盘密码与启动密码保持一致。**

---

### 三、 日常使用

1. **启动**：双击 `se.bat`。
2. **解锁**：输入密码（输入时不可见）。
3. **浏览**：验证通过后自动挂载加密盘、创建符号链接、启动 Edge。
4. **安全退出**：关闭 Edge 浏览器窗口后，加密盘自动卸载。

---

### 四、 三种模式的数据架构

#### [1] 全加密
```
Y:\EdgeUserData\              ← 所有 Edge 数据在加密盘
└── Default\                  ← 浏览器核心数据
```
最简单，最安全。无符号链接。

#### [2] 加密根+本地缓存（推荐）
```
Y:\EdgeUserData\              ← 核心数据在加密盘
├── Default\Login Data        ← 隐私文件（加密）
├── Default\History           ← 隐私文件（加密）
├── Default\Cache         → symlink → D:\...\EdgeUserData\Default\Cache
├── Default\Code Cache    → symlink → D:\...\EdgeUserData\Default\Code Cache
└── ...                       共 10 个缓存目录指向本地

D:\secure-edge\EdgeUserData\  ← 本地仅存大缓存（非隐私）
```

#### [3] 本地根+隐私加密
```
D:\secure-edge\EdgeUserData\  ← 用户数据在本地
├── Default\Login Data    → symlink → Y:\SecureProfile\Default\Login Data
├── Default\History       → symlink → Y:\SecureProfile\Default\History
└── ...                       共 49 个隐私文件/目录指向加密盘

Y:\SecureProfile\              ← 加密盘仅存隐私文件
```

---

### 五、 命令行参数

| 参数 | 作用 |
|---|---|
| `--setup-password` | 设置/修改启动密码 |
| `--setup-encryption` | 创建加密容器 |
| `--setup-mode` | 重新选择存储模式 |
| `--help` | 查看帮助 |
| 其他参数 | 透明传递给 msedge.exe |

---

### 六、 ⚠️ 注意事项

- **切勿丢失密码！** 启动密码或加密盘密码一旦遗忘，**没有任何后门可以找回**。
- **彻底关闭浏览器**：确保 Edge 的"后台扩展运行"已关闭（`edge://settings/system` → 关闭"在 Microsoft Edge 关闭后继续运行后台扩展和应用"），否则加密盘无法卸载。
- **杀毒软件**：涉及虚拟盘挂载和加密操作，部分杀软可能拦截。如遇问题，将脚本目录加入信任白名单。
- **数据备份**：所有核心数据在 `UserData.hc` 文件中。换电脑只需拷贝整个文件夹。
- **模式切换**：切换模式前建议备份 `EdgeUserData\` 目录。旧模式的数据在下次启动时会自动迁移。

---

### 七、 文件说明

| 文件/目录 | 说明 |
|---|---|
| `se.bat` | 启动脚本 |
| `se-enhanced.ps1` | 主程序 (PowerShell) |
| `UserData.hc` | VeraCrypt 加密容器 |
| `config_edge\password_edge.enc` | 启动密码哈希 |
| `config_edge\mode.cfg` | 存储模式选择 (1/2/3) |
| `EdgeUserData\` | 本地数据目录（模式 [3] 数据根；模式 [2] 仅缓存） |
| `veracrypt\` | VeraCrypt 便携版 |
