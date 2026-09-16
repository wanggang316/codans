// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DiffViewKit", platforms: [.macOS(.v14)], products: [.library(name: "DiffViewKit", targets: ["DiffViewKit"])], targets: [.target(name: "DiffViewKit", resources: [.copy("Resources/Web")])])
