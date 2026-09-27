
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
   name: "PlaneTasks",
   defaultLocalization: "en",
   platforms: [.macOS(.v14)],
   products: [
       .library(
           name: "PlaneTasks",
           type: .dynamic,
           targets: ["PlaneTasks"]
       )
   ],
   dependencies: [
       .package(
           url: "https://gitlab.com/droppyformac1/droppykit.git",
           from: "1.6.0"
       )
   ],
   targets: [
       .target(
           name: "PlaneTasks",
           dependencies: [
               .product(
                   name: "DroppyKit",
                   package: "droppykit"
               )
           ],
           resources: [
               .process("Resources")
           ]
       ),
       .executableTarget(
           name: "PlaneTasksHarness",
           dependencies: [
               "PlaneTasks",
               .product(
                   name: "DroppyKitHarness",
                   package: "droppykit"
               )
           ]
       )
   ]
)
