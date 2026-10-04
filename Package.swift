// swift-tools-version: 6.2
import PackageDescription

let package = Package(
   name: "PlaneTasks",
   defaultLocalization: "en",
   platforms: [.macOS(.v15)],
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
           from: "1.20.1"
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
