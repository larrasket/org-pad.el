// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "OrgPad",
    platforms: [ .iOS("16.0") ],
    products: [
        .iOSApplication(
            name: "OrgPad",
            targets: ["AppModule"],
            bundleIdentifier: "com.orgpad.OrgPad",
            teamIdentifier: nil,
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .pencil),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [ .pad ],
            supportedInterfaceOrientations: [
                .portrait, .landscapeRight, .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .localNetwork(
                    purposeString: "OrgPad discovers your Mac's Emacs server on the local network to receive and return drawings.",
                    bonjourServiceTypes: ["_orgpad._tcp"]
                )
            ]
        )
    ],
    targets: [ .executableTarget(name: "AppModule", path: ".") ]
)
