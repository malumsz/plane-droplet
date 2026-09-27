//
//  PlaneTasksHarness.swift
//
//  Run with: droppykit run
//
//  Not named main.swift on purpose: Swift treats that name as top-level code,
//  which cannot coexist with @main.
//

import DroppyKit
import DroppyKitHarness
import PlaneTasks

@main
struct PlaneTasksHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet { PlaneTasksDroplet() }
}
