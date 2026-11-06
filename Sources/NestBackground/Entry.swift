import Nest

@main
enum NestBackgroundEntry {
    @MainActor static func main() { NestEntry.main() }
}
