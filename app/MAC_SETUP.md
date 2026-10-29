# app/ 工程说明（Xcode + Mac 侧）

仓库里现在**已经有** `app/EnglishLearning.xcodeproj`，直接打开就能编译运行：

```bash
open app/EnglishLearning.xcodeproj
# 或者命令行：
cd app && xcodebuild -scheme EnglishLearning \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M2)' build
```

本文剩下部分是「工程里各项目前是什么值」「万一工程丢了怎么重建」「有哪些坑」，平时不用看。

---

## 1. 工程里已经配好的值

| 设置 | 值 |
|---|---|
| Target / Scheme | `EnglishLearning`（App） |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.aline117.englishlearning`（**定了就别改**） |
| `IPHONEOS_DEPLOYMENT_TARGET` | `18.0` |
| `TARGETED_DEVICE_FAMILY` | `2`（仅 iPad） |
| `GENERATE_INFOPLIST_FILE` | `NO` |
| `INFOPLIST_FILE` | `Support/Info.plist` |
| `CODE_SIGN_STYLE` | `Automatic`（Team 在 Xcode → Signing 里选自己的 Apple ID） |
| `SWIFT_VERSION` | `5.0`（不要开 Swift 6 严格并发，先跑通） |

target membership：

- `Sources/EnglishLearning/**`（含 `@main` 的 `EnglishLearningApp.swift`）→ Compile Sources
- `Resources/catalog.json` → Copy Bundle Resources（内置学期目录，几 KB）
- `Support/PrivacyInfo.xcprivacy` → Copy Bundle Resources
- `Assets.xcassets` → Copy Bundle Resources，并设 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`

图标源文件在 `Assets.xcassets/AppIcon.appiconset/AppIcon.png`（1024×1024，不透明，圆角由 iOS 切）。
想改配色/构图就改 `tools/MakeIcon.swift` 后重新生成：

```bash
swift app/tools/MakeIcon.swift app/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

**App 里不再打包课文内容**（design Decision 3「零内置」）：学期包由 `content-service/build/build_resources.py`
产出 `content-service/packs/g2s1.zip`，iPad 在家长模式 → 内容管理里下载，装到
`Application Support/Curriculum/<semester>/`，再由 `ResourceLocator` 按相对路径取音频和图片。

`app/Resources/Curriculum/` 只作为**打包源**留在仓库里（SPM 备用路径还会带上它，真机不受影响），
等 tasks 7.7 决定是否把它彻底移出 git。

依赖：`ZIPFoundation`（远程 SPM，0.9.19+）已加进工程，只有 `ContentInstaller` import 它（解压学期包）。

---

## 2. 万一工程丢了：手建清单

- Xcode → File → New → Project → **iOS → App**
- Product Name：`EnglishLearning`；Interface：**SwiftUI**；Language：**Swift**
- 位置：仓库里的 `app/`（即 `app/EnglishLearning.xcodeproj`）
- 不勾 Core Data / Tests

然后按第 1 节的表改 Build Settings，再：

- 删掉模板生成的 `ContentView.swift` / `EnglishLearningApp.swift`
- 把 `Sources/EnglishLearning` 拖进工程（Create groups，勾 target）
- 把 `Resources/Curriculum` 拖进去，勾 **Create folder references**（不是 Create groups！）
  - ⚠️ 拖 `Resources` 整个目录、让它在 App 包里叫 `Resources/` 会**签名失败**，见第 3 节
- 把 `Support/PrivacyInfo.xcprivacy` 拖进去，Target Membership 勾上

---

## 3. 内容从哪来

```bash
python3 content-service/build/build_resources.py     # 打包 → content-service/packs/g2s1.zip + meta
python3 content-service/serve/serve.py               # 起内容服务（或 node content-service/serve/serve.js）
```

iPad 上：家长模式（右上角 🔒）→ 内容管理 → 填 `<host>.local:8080` → 连接 → 下载。
细节见 `content-service/README.md`。

## 4. 已经踩过的坑

| 现象 | 原因 / 处理 |
|---|---|
| `CodeSign failed`：`code object is not signed at all. In subcomponent: .../PrivacyInfo.xcprivacy` | App 包里只要出现**顶层 `Resources/` 目录**，codesign 就会把散装的根目录文件当成代码去验签。把 folder reference 指到 `Resources/Curriculum`（包内叫 `Curriculum`）即可 |
| `找不到课程资源: grade2.json` | `Resources/Curriculum` 被当成 group（Create groups）而不是 folder reference，目录层级塌了；或者 folder reference 名字不是 `Curriculum` |
| 编译报 `type 'Bundle' has no member 'module'` | `Bundle.module` 只有 SwiftPM 构建才有。`CurriculumLoader.resourceBundle` 已用 `#if SWIFT_PACKAGE` 分开：SPM → `.module`，Xcode App target → `.main`。手建工程时别把这段改回去 |
| 提示隐私清单缺失 | `PrivacyInfo.xcprivacy` 没勾 target membership，或没放进 Copy Bundle Resources |
| 麦克风/本地网络没弹权限 | `INFOPLIST_FILE` 没指到 `Support/Info.plist`（用了自动生成的 plist） |
| 无法打开本地数据库，本次以内存模式运行 | `Schema` 改过、旧库不兼容。开发期正常：删掉 App 重装即可（学习记录会丢，design 里已明示"卸载即丢失"） |

---

## 5. ZIPFoundation（已接进工程）

Xcode 工程里已加 `https://github.com/weichsel/ZIPFoundation.git`（Up to Next Major，0.9.19 起），
`ContentInstaller` 用它的 `FileManager.unzipItem(at:to:)` 解学期包（iOS SDK 没有 zip 解包 API）。
`Package.swift` 里声明的是同一条依赖，给「把 `app/` 当 SPM 包构建」的备用路径用，两边互不影响。

⚠️ 首次构建需要访问 GitHub 拉包；拉过一次后走缓存，离线也能编译。

---

## 6. 真机跑起来

- iPad 用数据线连 Mac，Xcode 顶部选这台 iPad
- Signing & Capabilities → Team 选自己的 Apple ID；首次要在这台 iPad 上「信任」开发者
- ⌘R 运行
- 免费 Apple ID 签名 **7 天过期**，到期重新 ⌘R 一次即可（数据保留）

---

## 7. 第一次运行会看到什么

- 一个「给自己起个名字吧」的页面（`ProfileSetupView`）
- 输入名字 → 「学习 / 奖励」两个 Tab，顶部右上角有把小锁（家长模式入口）
- **还没下载内容**时学习 Tab 显示「还没有学习内容」，提示家长去内容管理下载
- 家长模式 → 内容管理：连上内容服务后下载「二年级上」，装完回学习 Tab
- 学习 Tab：二年级 → 单元列表（未解锁单元带锁）→ 单元页：单词/句型/课文原声都能点开听
