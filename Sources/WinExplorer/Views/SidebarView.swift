import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: BrowserModel

    private let quickPlaces = Place.quickPlaces
    private let volumes = Place.volumes

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                Section("常用") {
                    ForEach(quickPlaces) { place in
                        placeRow(place)
                    }
                }
                if !volumes.isEmpty {
                    Section("设备") {
                        ForEach(volumes) { place in
                            placeRow(place)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Text("WinExplorer 0.1 · MVP")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    private var selectionBinding: Binding<URL?> {
        Binding(
            get: { model.currentURL },
            set: { newValue in
                if let url = newValue {
                    model.navigate(to: url)
                }
            }
        )
    }

    private func placeRow(_ place: Place) -> some View {
        Label {
            Text(place.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
        } icon: {
            Image(nsImage: IconProvider.shared.icon(for: place.url))
                .resizable()
                .frame(width: 15, height: 15)
        }
        .tag(place.url)
    }
}
