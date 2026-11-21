// swift-tools-version:5.9
//
// GTube for macOS: a native YouTube and YouTube Music client.
//
//   swift build -c release      # the program (needs `brew install mpv pkgconf`)
//   swift test                  # parser and logic tests (GTubeCore)
//   packaging/bundle.sh         # build/GTube.app, with libmpv, yt-dlp and deno inside
import PackageDescription

let package = Package(
    name: "GTube",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GTube", targets: ["GTube"]),
        .library(name: "GTubeCore", targets: ["GTubeCore"]),
    ],
    targets: [
        // libmpv's C API (client + OpenGL render API), found through pkg-config.
        .systemLibrary(
            name: "CMpv",
            path: "Sources/CMpv",
            pkgConfig: "mpv",
            providers: [.brew(["mpv"])]
        ),
        // Everything that isn't UI: the InnerTube client and its parsers,
        // YouTube Music, lyrics, watch-history reports, SponsorBlock, Return
        // YouTube Dislike and yt-dlp. Foundation only.
        .target(
            name: "GTubeCore",
            path: "Sources/GTubeCore"
        ),
        // The app: SwiftUI + AppKit, playback through libmpv.
        .executableTarget(
            name: "GTube",
            dependencies: ["GTubeCore", "CMpv"],
            path: "Sources/GTube",
            linkerSettings: [
                .linkedFramework("OpenGL"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "GTubeCoreTests",
            dependencies: ["GTubeCore"],
            path: "Tests/GTubeCoreTests"
        ),
    ]
)
