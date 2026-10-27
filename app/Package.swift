// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EnglishLearning",
    // iOS 18：`#Unique` / `#Index` 依赖 18 起的能力（见 design Decision 1）。
    // 写 "18.0" 而不是 `.v18`：`.v18` 需要 swift-tools-version 6.0，这里保持 5.9。
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "EnglishLearning", targets: ["EnglishLearning"])
    ],
    dependencies: [
        // iOS 无原生 zip API，学期包解压用它（见 design Decision 3）
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .target(
            name: "EnglishLearning",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: ".",
            sources: ["Sources/EnglishLearning"],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
