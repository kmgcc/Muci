import AppKit
import MotionKit
import SwiftUI
import UniformTypeIdentifiers

/// Panel, dialog and progress state for skin package management in the selector row.
/// Installation itself is owned by SkinPackageStore.
@MainActor
@Observable
final class SkinPackageActionModel {
    struct Removal: Identifiable {
        let id: String
        let isLinkedDirectory: Bool
    }

    /// An archive that passed validation and waits for the user to confirm installing it.
    struct PendingImport {
        let name: String
        let author: String?
        let uses: [SkinPackageUse]
        /// An earlier import has this ID: the user replaces it or keeps both.
        let conflicts: Bool

        var title: String { "安装“\(name)”？" }

        var message: String {
            var lines: [String] = []
            if let author { lines.append("作者：\(author)") }
            if uses.isEmpty {
                lines.append("包含场景与图片。")
            } else {
                lines.append("包含\(uses.map(\.title).joined(separator: "、"))，安装后在播放界面中运行。仅安装来源可信的皮肤包。")
            }
            if conflicts { lines.append("已有此皮肤，可替换或另存副本。") }
            return lines.joined(separator: "\n")
        }
    }

    var isWorking = false
    var pendingArchive: URL?
    var pendingImport: PendingImport?
    var pendingRemoval: Removal?
    var errorMessage: String?

    static func package(_ skinID: String, in manager: SkinManager) -> PackagedSkin? {
        guard let package = manager.catalog.registeredSkin(for: skinID) as? PackagedSkin,
              package.isExportable else { return nil }
        return package
    }

    func chooseArchive(manager: SkinManager) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            pendingArchive = url
            isWorking = true
            Task { @MainActor in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() }; isWorking = false }
                do {
                    let inspection = try await manager.catalog.packages.inspectForImport(url)
                    let manifest = inspection.manifest
                    let author = manifest.author?.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Only an earlier import with this ID conflicts; one over a shipped skin or behind a linked folder goes in beside it.
                    pendingImport = PendingImport(
                        name: manifest.descriptor.name,
                        author: author?.isEmpty == false ? author : nil,
                        uses: inspection.uses,
                        conflicts: manager.catalog.packages.installedDirectory(for: manifest.descriptor.id) != nil
                    )
                } catch {
                    pendingArchive = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func importPending(_ disposition: SkinPackageImportDisposition, manager: SkinManager) {
        guard let url = pendingArchive else { return }
        isWorking = true
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() }; isWorking = false; pendingArchive = nil }
            do { _ = try await manager.catalog.packages.importPackage(url, disposition: disposition) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func chooseDevelopmentDirectory(manager: SkinManager) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try manager.catalog.developmentDirectories.attachChosen(url) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func export(_ skin: PackagedSkin, manager: SkinManager) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(skin.name).zip"
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            isWorking = true
            Task { @MainActor in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() }; isWorking = false }
                do { try await manager.catalog.packages.exportPackage(skin, to: url) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

    func reload(_ skinID: String, manager: SkinManager) {
        do { try manager.catalog.reload(skinID) }
        catch { errorMessage = error.localizedDescription }
    }

    func reveal(_ skin: PackagedSkin) {
        if let url = skin.origin.packageDirectory { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func requestRemoval(_ skin: PackagedSkin) {
        if case .development = skin.origin {
            pendingRemoval = Removal(id: skin.id, isLinkedDirectory: true)
        } else {
            pendingRemoval = Removal(id: skin.id, isLinkedDirectory: false)
        }
    }

    func remove(_ removal: Removal, manager: SkinManager, settings: AppSettings) {
        do { try manager.removePackage(removal.id, settings: settings) }
        catch { errorMessage = error.localizedDescription }
    }
}

/// Right-click menu for one skin card. Native skins have no package actions; shipped packages
/// keep export, reload and reveal, and only imports and linked folders can be removed.
struct SkinPackageCardMenu: View {
    let skinID: String
    let model: SkinPackageActionModel
    @Environment(SkinManager.self) private var manager

    var body: some View {
        if let package = SkinPackageActionModel.package(skinID, in: manager) {
            Button("导出", systemImage: "square.and.arrow.up") { model.export(package, manager: manager) }
            Button("重载", systemImage: "arrow.clockwise") { model.reload(skinID, manager: manager) }
            Button("在访达中显示", systemImage: "folder") { model.reveal(package) }
            switch package.origin {
            case .development:
                Divider()
                Button("移除关联", systemImage: "link.badge.minus", role: .destructive) { model.requestRemoval(package) }
            case .installed:
                Divider()
                Button("删除", systemImage: "trash", role: .destructive) { model.requestRemoval(package) }
            case .bundled:
                EmptyView()
            }
        }
    }
}

/// Trailing card that adds a skin: import a ZIP or link an author directory.
struct SkinPackageAddCard: View {
    let model: SkinPackageActionModel
    let cardWidth: CGFloat
    let cornerRadius: CGFloat
    let titleFontSize: CGFloat
    @Environment(SkinManager.self) private var manager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors
    @State private var isHovering = false

    private var foregroundColor: Color {
        if presentationStyle.usesUnifiedOverlayForeground {
            return presentationStyle.primaryTextColor.opacity(0.72)
        }
        if let appColors { return appColors.secondary }
        return colorScheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.55)
    }

    private var surfaceColor: Color {
        if presentationStyle.usesUnifiedOverlayForeground {
            return presentationStyle.primaryTextColor.opacity(0.045)
        }
        if let appColors { return appColors.secondary.opacity(0.08) }
        return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    var body: some View {
        let geometry = SkinCardGeometry(width: cardWidth, cornerRadius: cornerRadius, titleFontSize: titleFontSize)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        SkinCardLayout(geometry: geometry, title: "添加", titleFontSize: titleFontSize, titleColor: foregroundColor) {
            ZStack {
                RoundedRectangle(cornerRadius: geometry.innerCornerRadius, style: .continuous)
                    .fill(surfaceColor)
                if model.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: titleFontSize * 2, weight: .light))
                        .foregroundStyle(foregroundColor)
                }
            }
        }
        .background(shape.fill(surfaceColor))
        .clipShape(shape)
        .contentShape(shape)
        .opacity(isHovering ? 0.88 : 1.0)
        .motionAnimation(.microInteraction, value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: showMenu)
        .contextMenuWithVisibleIcons { menuItems }
        .disabled(model.isWorking)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("导入皮肤包", systemImage: "square.and.arrow.down") { model.chooseArchive(manager: manager) }
        Button("关联目录", systemImage: "folder.badge.plus") { model.chooseDevelopmentDirectory(manager: manager) }
    }

    /// A left click opens the same choices as a menu at the pointer.
    private func showMenu() {
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        let menu = NSMenu()
        menu.addItem(SkinPackageMenuItem(title: "导入皮肤包", symbol: "square.and.arrow.down") { [model, manager] in
            model.chooseArchive(manager: manager)
        })
        menu.addItem(SkinPackageMenuItem(title: "关联目录", symbol: "folder.badge.plus") { [model, manager] in
            model.chooseDevelopmentDirectory(manager: manager)
        })
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

nonisolated private final class SkinPackageMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func runHandler() { handler() }
}

/// Conflict, removal and error dialogs shared by the card menus and the add card.
struct SkinPackageActionDialogs: ViewModifier {
    @Bindable var model: SkinPackageActionModel
    @Environment(SkinManager.self) private var manager
    @Environment(AppSettings.self) private var settings

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                model.pendingImport?.title ?? "",
                isPresented: Binding(get: { model.pendingImport != nil }, set: { if !$0 { model.pendingImport = nil } }),
                titleVisibility: .visible,
                presenting: model.pendingImport
            ) { pending in
                if pending.conflicts {
                    Button("替换") { model.importPending(.replace, manager: manager) }
                    Button("另存副本") { model.importPending(.copy, manager: manager) }
                } else {
                    Button("安装") { model.importPending(.copy, manager: manager) }
                }
                Button("取消", role: .cancel) { model.pendingArchive = nil }
            } message: { pending in
                Text(pending.message)
            }
            .confirmationDialog(
                model.pendingRemoval?.isLinkedDirectory == true ? "移除此关联？" : "删除此皮肤？",
                isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: model.pendingRemoval
            ) { removal in
                Button(removal.isLinkedDirectory ? "移除关联" : "删除", role: .destructive) {
                    model.remove(removal, manager: manager, settings: settings)
                }
                Button("取消", role: .cancel) {}
            } message: { removal in
                Text(removal.isLinkedDirectory ? "源文件保留，正在使用的皮肤将切回内置皮肤" : "正在使用的皮肤将切回内置皮肤")
            }
            .alert("皮肤包", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("好", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
}
