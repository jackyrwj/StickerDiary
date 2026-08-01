import SwiftUI

private enum CreateRoute: Hashable {
    case generation(GenerationRequest)
}

struct CreateFlowView: View {
    let library: StickerLibrary
    let onSaved: () -> Void
    @State private var path: [CreateRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            CreateStickerView { request in
                path.append(.generation(request))
            }
            .navigationDestination(for: CreateRoute.self) { route in
                switch route {
                case .generation(let request):
                    GenerationView(request: request, library: library) {
                        path.removeAll()
                        onSaved()
                    }
                }
            }
        }
    }
}
