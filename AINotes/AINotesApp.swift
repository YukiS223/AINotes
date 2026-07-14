import SwiftUI
import SwiftData

@main
struct AINotesApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Notebook.self,
            Page.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        } catch {
            // A schema change can make the OLD on-disk store unmigratable
            // during development. The old fallback silently switched to an
            // IN-MEMORY store: the app looked fine but every note written
            // that session evaporated on quit, forever, with no indication.
            // Instead: move the incompatible store aside (recoverable) and
            // start a fresh PERSISTENT one. (A shipped app would use a
            // SchemaMigrationPlan; still a deferred item.)
            print("⚠️ ModelContainer failed to open existing store: \(error)")
            let fm = FileManager.default
            if let support = fm.urls(for: .applicationSupportDirectory,
                                     in: .userDomainMask).first {
                let stamp = Int(Date.now.timeIntervalSince1970)
                for name in ["default.store", "default.store-shm", "default.store-wal"] {
                    let url = support.appendingPathComponent(name)
                    if fm.fileExists(atPath: url.path) {
                        try? fm.moveItem(
                            at: url,
                            to: support.appendingPathComponent("\(name).incompatible-\(stamp)")
                        )
                    }
                }
            }
            print("⚠️ Moved incompatible store aside; creating a fresh persistent store.")
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: [modelConfiguration]
                )
            } catch {
                fatalError("Could not create fresh ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
