import Nest

@main
enum NestLauncherEntry {
    @MainActor static func main() { NestEntry.main() }
}
