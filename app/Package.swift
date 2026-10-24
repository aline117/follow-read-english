// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EnglishLearning",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "EnglishLearning", targets: ["EnglishLearning"])
    ],
    targets: [
        .target(
            name: "EnglishLearning",
            path: ".",
            sources: ["Sources/EnglishLearning"],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
