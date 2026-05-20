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
            // during development. Rather than hard-crashing, log it and
            // start from a fresh store. (In a shipped app with real user
            // data you'd write a SchemaMigrationPlan instead — noted as a
            // deferred item, not done here.)
            print("⚠️ ModelContainer failed to open existing store: \(error)")
            print("⚠️ Falling back to a fresh in-memory-safe store.")
            let fallback = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: [fallback]
                )
            } catch {
                fatalError("Could not create fallback ModelContainer: \(error)")
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
