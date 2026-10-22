// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Payriff",
    platforms: [
        .iOS(.v16),
        // The card form and the 3-D Secure sheet are iOS-only. macOS is declared so that
        // `swift build` and `swift test` can compile and test the UI-free core (validation,
        // encryption, the Client API and the card payment flow) on a Mac.
        .macOS(.v13),
    ],
    products: [
        .library(name: "Payriff", targets: ["Payriff"]),
    ],
    targets: [
        .target(
            name: "Payriff",
            path: "Sources/Payriff",
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
                // The badges and the light and dark logos of PayriffPaymentView (CONTRACT §16.14),
                // as bundle images in 1x, 2x and 3x. The lock is drawn in code.
                .process("Resources/PaymentView"),
            ]
        ),
        .testTarget(
            name: "PayriffTests",
            dependencies: ["Payriff"],
            path: "Tests/PayriffTests",
            resources: [.copy("Resources/vectors")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
