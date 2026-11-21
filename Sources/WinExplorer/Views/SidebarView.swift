import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var favorites = FavoritesStore.shared
    /// 拖拽悬停中的侧边栏位置
    @State private var targetedPlace: URL?
    /// 拖到「收藏夹」标题上（= 加收藏，而不是移动到某个目录）
    @State private var favoritesTargeted = false

    private let quickPlaces = Place.quickPlaces
    private let volumes = Place.volumes

    /// 已经在收藏夹里的位置不再在「常用 / 设备」里重复出现，
    /// 否则同一个 URL 会在侧边栏出现两次、且同时高亮。
    private var plainQuickPlaces: [Place] {
        quickPlaces.filter { !favorites.contains($0.url) }
    }

    private var plainVolumes: [Place] {
        volumes.filter { !favorites.contains($0.url) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                Section {
                    if favorites.items.isEmpty {
                        favoritesHint
                    } else {
                        ForEach(favorites.items) { place in
                            favoriteRow(place)
                        }
                    }
                } header: {
                    favoritesHeader
                }

                if !plainQuickPlaces.isEmpty {
                    Section("常用") {
                        ForEach(plainQuickPlaces) { place in
                            placeRow(place)
                        }
                    }
                }
                if !plainVolumes.isEmpty {
                    Section("设备") {
                        ForEach(plainVolumes) { place in
                            placeRow(place)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Text("WinExplorer \(Self.appVersion) · MVP")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    /// 侧边栏底部显示的版本号，跟随 Info.plist
    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
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

    // MARK: - 收藏夹

    private var favoritesHeader: some View {
        HStack(spacing: 4) {
            Text("收藏夹")
            Spacer(minLength: 2)
            Button {
                model.addCurrentDirectoryToFavorites()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(favoritesTargeted ? Color.accentColor : Color.secondary)
            .help("把当前文件夹加入收藏夹")
        }
        .padding(.vertical, 1)
        .padding(.trailing, 4)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(favoritesTargeted ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $favoritesTargeted) { providers in
            addDroppedFolders(providers)
        }
    }

    private var favoritesHint: some View {
        Text("把文件夹拖到这里，或点 + 收藏当前文件夹")
            .font(.system(size: 10.5))
            .foregroundStyle(favoritesTargeted ? Color.accentColor : Color.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 3)
            .onDrop(of: [UTType.fileURL], isTargeted: $favoritesTargeted) { providers in
                addDroppedFolders(providers)
            }
    }

    private func favoriteRow(_ place: Place) -> some View {
        placeRow(place)
            .contextMenu {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([place.url])
                }
                Divider()
                Button("从收藏夹移除") {
                    favorites.remove(place.url)
                }
            }
    }

    /// 拖到收藏夹区域：只收文件夹，加完给个反馈
    private func addDroppedFolders(_ providers: [NSItemProvider]) -> Bool {
        DropSupport.loadURLs(from: providers) { urls in
            let folders = urls.filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            guard !folders.isEmpty else {
                model.showFlash("只能把文件夹加入收藏夹")
                return
            }
            var added = 0
            for folder in folders where favorites.add(folder) {
                added += 1
            }
            model.showFlash(added > 0 ? "已收藏 \(added) 个文件夹" : "这些文件夹已经在收藏夹里")
        }
        return true
    }

    // MARK: - 普通位置

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
        .listRowBackground(
            targetedPlace == place.url
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
        .onDrop(of: [UTType.fileURL], isTargeted: targetedBinding(for: place.url)) { providers in
            DropSupport.loadURLs(from: providers) { urls in
                guard !urls.isEmpty else { return }
                model.drop(urls: urls, into: place.url, modifiers: NSEvent.modifierFlags)
            }
            return true
        }
    }

    private func targetedBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { targetedPlace == url },
            set: { isTargeted in
                if isTargeted {
                    targetedPlace = url
                } else if targetedPlace == url {
                    targetedPlace = nil
                }
            }
        )
    }
}
