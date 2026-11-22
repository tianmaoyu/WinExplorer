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
    private let networkVolumes = Place.networkVolumes

    /// 已经在收藏夹里的位置不再在「常用 / 设备 / 网络」里重复出现，
    /// 否则同一个 URL 会在侧边栏出现两次、且同时高亮。
    private var plainQuickPlaces: [Place] {
        quickPlaces.filter { !favorites.contains($0.url) }
    }

    private var plainVolumes: [Place] {
        volumes.filter { !favorites.contains($0.url) }
    }

    private var plainNetworkVolumes: [Place] {
        networkVolumes.filter { !favorites.contains($0.url) }
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
                    Section(L("常用", "Places")) {
                        ForEach(plainQuickPlaces) { place in
                            placeRow(place)
                        }
                    }
                }
                if !plainVolumes.isEmpty {
                    Section(L("设备", "Devices")) {
                        ForEach(plainVolumes) { place in
                            placeRow(place)
                        }
                    }
                }
                if !plainNetworkVolumes.isEmpty {
                    Section(L("网络", "Network")) {
                        ForEach(plainNetworkVolumes) { place in
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

    /// 选中态读 `selectionURL` 而不是 `currentURL`（adr/0025）：
    /// `currentURL` 要等后台读完成才更新，拿它当选中态会先被回读成旧目录，
    /// 界面就会出现「b → a → b」的闪烁。
    private var selectionBinding: Binding<URL?> {
        Binding(
            get: { model.selectionURL },
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
            Text(L("收藏夹", "Favorites"))
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
            .help(L("把当前文件夹加入收藏夹", "Add the current folder to favorites"))
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
        Text(L("把文件夹拖到这里，或点 + 收藏当前文件夹",
               "Drag folders here, or click + to save the current folder"))
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
                Button(L("在 Finder 中显示", "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([place.url])
                }
                Divider()
                Button(L("从收藏夹移除", "Remove from Favorites")) {
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
                model.showFlash(L("只能把文件夹加入收藏夹", "Only folders can be added to Favorites"))
                return
            }
            var added = 0
            for folder in folders where favorites.add(folder) {
                added += 1
            }
            model.showFlash(added > 0
                ? L("已收藏 \(added) 个文件夹", "Added \(added) folder(s) to Favorites")
                : L("这些文件夹已经在收藏夹里", "Those folders are already in Favorites"))
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
