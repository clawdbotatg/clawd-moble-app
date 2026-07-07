import SwiftUI

@main
struct ClawdChatApp: App {
    @State private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            ChatView(store: store)
        }
    }
}
