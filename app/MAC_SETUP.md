# Mac 侧建工程清单（一次性，约 10 分钟）

仓库里没有 `.xcodeproj`（`.gitignore` 里也没有它），工程在 Mac 上用 Xcode 手建一次即可。
下面这些值要和 `Support/Info.plist`、`Package.swift` 对齐，否则会白折腾。

## 1. 新建工程

- Xcode → File → New → Project → **iOS → App**
- Product Name：`EnglishLearning`
- Interface：**SwiftUI**，Language：**Swift**
- 位置：`F:`/Mac 上对应的仓库根目录下的 `app/`（即 `app/EnglishLearning.xcodeproj`）
- 不要勾选 Core Data / Tests（测试后面单独加也可以）

## 2. Build Settings（必须改）

| 设置 | 值 |
|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.aline117.englishlearning`（**定了就别改**） |
| `IPHONEOS_DEPLOYMENT_TARGET` | `18.0` |
| `TARGETED_DEVICE_FAMILY` | `2`（仅 iPad） |
| `GENERATE_INFOPLIST_FILE` | `NO` |
| `INFOPLIST_FILE` | `Support/Info.plist` |
| `DEVELOPMENT_TEAM` | 你的免费 Apple ID 对应的 Team |
| `CODE_SIGN_STYLE` | `Automatic` |
| `SWIFT_VERSION` | `5.0`（别开 Swift 6 严格并发，先跑通） |

⚠️ `INFOPLIST_FILE` 是相对**工程文件所在目录**的路径，所以在 `app/` 下建工程时写 `Support/Info.plist`。

## 3. 把源码和资源加进 target

删掉模板生成的 `ContentView.swift` / `EnglishLearningApp.swift`，然后：

- 把 `Sources/EnglishLearning` 整个文件夹拖进工程，勾选 **Create groups**、**Add to target: EnglishLearning**
- 把 `Resources` 文件夹拖进去，勾选 **Create folder references**（保持目录结构，`Curriculum/img/u1/...` 这些相对路径才不会断）
- 把 `Support/PrivacyInfo.xcprivacy` 拖进去，**Target Membership 勾上**（它不在 Resources 里也要单独加）

## 4. ZIPFoundation

- File → Add Package Dependencies…
- 输入 `https://github.com/weichsel/ZIPFoundation.git`
- Dependency Rule：**Up to Next Major**，从 `0.9.19` 起
- 添加到 target `EnglishLearning`

（`app/Package.swift` 里也声明了同一个依赖，是给「把这个目录当 SPM 包」的备用路径；手建工程时以 Xcode 的 Add Package 为准，Package.swift 不参与构建。）

## 5. 真机跑起来

- iPad 用数据线连 Mac，Xcode 顶部选这台 iPad
- Signing & Capabilities → Team 选自己的 Apple ID；首次要在这台 iPad 上「信任」开发者
- ⌘R 运行
- 免费 Apple ID 签名 **7 天过期**，到期重新 ⌘R 一次即可（数据保留）

## 6. 第一次运行会看到什么

- 一个输入名字的页面（`ProfileSetupView`）
- 输入后进「学习 / 奖励」两个 Tab，右上角有把小锁（家长模式入口）
- 年级卡片只有「二年级」是亮的，其余灰着（正式页面见 tasks 3.x）
- 家长模式里 6 个入口都能点，进去是占位页（正式的见 tasks 6.x）

## 7. 常见问题

| 现象 | 原因 |
|---|---|
| 「无法打开本地数据库，本次以内存模式运行」 | `Schema` 改过、旧数据库不兼容。开发期正常：删掉 App 重装即可（学习记录会丢，`design` 里已明示"卸载即丢失"） |
| 找不到 `grade2.json` | `Resources` 被当成 group 而不是 folder reference，目录层级塌了 |
| 提示隐私清单缺失 | `PrivacyInfo.xcprivacy` 没勾 target membership |
| 麦克风/本地网络没弹权限 | `INFOPLIST_FILE` 没指到 `Support/Info.plist`（Xcode 用了自动生成的 plist） |
