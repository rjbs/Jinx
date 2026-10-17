// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Jinx",
  platforms: [
    .macOS("27.0"),
    .iOS("27.0"),
  ],
  products: [
    .library(name: "Jinx", targets: ["Jinx"]),
    .library(name: "JinxTypes", targets: ["JinxTypes"]),
    .library(name: "JinxWire", targets: ["JinxWire"]),
    .library(name: "JinxPatch", targets: ["JinxPatch"]),
    .library(name: "JinxJSON", targets: ["JinxJSON"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
  ],
  targets: [
    .target(name: "JinxJSON"),
    .target(name: "JinxPatch", dependencies: ["JinxJSON"]),
    .target(name: "JinxWire", dependencies: ["JinxJSON"]),
    .target(
      name: "JinxStore",
      dependencies: [
        "JinxJSON",
        "JinxWire",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .target(name: "Jinx", dependencies: ["JinxJSON", "JinxPatch", "JinxWire", "JinxStore"]),
    .target(name: "JinxTypes", dependencies: ["Jinx"]),

    .testTarget(name: "JinxJSONTests", dependencies: ["JinxJSON"]),
    .testTarget(name: "JinxPatchTests", dependencies: ["JinxPatch"]),
    .testTarget(name: "JinxWireTests", dependencies: ["JinxWire"]),
    .testTarget(name: "JinxStoreTests", dependencies: ["JinxStore"]),
    .testTarget(name: "JinxTests", dependencies: ["Jinx"]),
  ],
  swiftLanguageModes: [.v6]
)
