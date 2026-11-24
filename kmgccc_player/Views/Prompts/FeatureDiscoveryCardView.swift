//
//  FeatureDiscoveryCardView.swift
//  kmgccc_player
//
//  The card that introduces a feature, and its main-window presenter.
//

import PopupKit
import SwiftUI

struct FeatureDiscoveryCardView: View {
    let copy: FeatureDiscoveryCopy
    let cohort: UserCohort
    let preview: DiscoveryPreviewAsset
    let onPrimary: @MainActor () -> Void
    let onSecondary: @MainActor () -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    private static let width: CGFloat = 448
    private static let previewAspectRatio: CGFloat = 16.0 / 10.0
    private static let titleSize: CGFloat = 28

    var body: some View {
        let style = PopupStyle()
        PopupSurface {
            VStack(alignment: .leading, spacing: 0) {
                previewView
                    .frame(width: Self.width, height: Self.width / Self.previewAspectRatio)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: style.cornerRadius,
                        topTrailingRadius: style.cornerRadius,
                        style: .continuous
                    ))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: style.titleBodySpacing + 4) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(copy.featureName)
                            .font(.system(size: Self.titleSize, weight: .semibold))
                        Text(copy.badge(for: cohort))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(themeStore.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(themeStore.accentColor.opacity(0.14), in: Capsule())
                    }

                    Text(copy.body)
                        .font(.system(size: style.bodySize))
                        .foregroundStyle(.secondary)
                        .lineSpacing(style.bodyLineSpacing - 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, style.padding)
                .padding(.top, style.padding - 2)

                AppDialogFooter {
                    Button(copy.secondaryButtonTitle, action: onSecondary)
                        .buttonStyle(AppDialogGlassButtonStyle(kind: .secondary))
                    Button(copy.primaryButtonTitle, action: onPrimary)
                        .buttonStyle(AppDialogGlassButtonStyle(kind: .primary))
                }
                .padding(.top, 6)
            }
            .frame(width: Self.width)
        }
        .appPopupAppearance()
        .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder private var previewView: some View {
        switch preview {
        case .loopingVideo(let name, let ext, let posterName, let posterExt):
            if let videoURL = Bundle.main.url(forResource: name, withExtension: ext) {
                SilentLoopingVideoView(
                    videoURL: videoURL,
                    posterURL: Bundle.main.url(forResource: posterName, withExtension: posterExt)
                )
            } else {
                themeStore.accentColor.opacity(0.12)
            }
        }
    }
}

/// Shows discovery cards through the main window's modal layer.
@MainActor
final class MainWindowFeatureDiscoveryPresenter: FeatureDiscoveryPresenting {
    private let modalPresenter: MainWindowModalPresenter

    init(modalPresenter: MainWindowModalPresenter = .shared) {
        self.modalPresenter = modalPresenter
    }

    func present(
        _ item: FeatureDiscoveryItem,
        cohort: UserCohort,
        onPrimary: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        let card = FeatureDiscoveryCardView(
            copy: item.copy,
            cohort: cohort,
            preview: item.preview,
            onPrimary: onPrimary,
            onSecondary: onDismiss
        )
        modalPresenter.present(MainWindowModal(
            id: Self.modalID(for: item),
            content: AnyView(card),
            onDefaultAction: onPrimary
        ))
    }

    func dismiss(_ item: FeatureDiscoveryItem) {
        modalPresenter.dismiss(id: Self.modalID(for: item))
    }

    private static func modalID(for item: FeatureDiscoveryItem) -> String {
        "featureDiscovery.\(item.id)"
    }
}
