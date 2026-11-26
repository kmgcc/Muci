//
//  SkinSelectorRow.swift
//  myPlayer2
//
//  kmgccc_player - Horizontal scrolling skin card selector.
//

import SwiftUI

/// Built-in skins with a hand-drawn preview; every other skin draws its package preview.
let skinDrawnPreviewIDs: Set<String> = ["coverLed", "appleStyle", "rotatingCover", "kmgccc.cassette", "fullscreen.coverGradientBlur"]

/// Maps a skin identifier to its minimal vector preview.
@ViewBuilder
func skinPreview(for id: String, isSelected: Bool, accentColor: Color) -> some View {
    switch id {
    case "coverLed":
        ClassicSkinPreview(isSelected: isSelected, accentColor: accentColor)
    case "appleStyle":
        AppleStyleSkinPreview(isSelected: isSelected, accentColor: accentColor)
    case "rotatingCover":
        RotatingSkinPreview(isSelected: isSelected, accentColor: accentColor)
    case "kmgccc.cassette":
        CassetteSkinPreview(isSelected: isSelected, accentColor: accentColor)
    case "fullscreen.coverGradientBlur":
        CoverGradientBlurSkinPreview(isSelected: isSelected, accentColor: accentColor)
    default:
        ClassicSkinPreview(isSelected: isSelected, accentColor: accentColor)
    }
}

/// Horizontal scrollable row of skin preview cards with edge fade masks.
struct SkinSelectorRow: View {
    let skins: [SkinOption]
    @Binding var selectedSkinID: String
    var cardSize: CGSize = CGSize(width: 104, height: 124)
    var previewSize: CGFloat = 80
    var cornerRadius: CGFloat = 12
    var titleFontSize: CGFloat = 11
    var itemSpacing: CGFloat = 10
    var edgePadding: CGFloat = 10
    var verticalPadding: CGFloat = 4
    var showsScrollButtons: Bool = true
    /// Adds per-card package menus and a trailing add card.
    var managesPackages: Bool = false
    /// Which scene a package preview outlines.
    var surface: SkinSurface = .window
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    private var previewForeground: Color {
        if presentationStyle.usesUnifiedOverlayForeground { return presentationStyle.primaryTextColor }
        return appColors?.primary ?? .primary
    }
    @State private var packageActions = SkinPackageActionModel()

    var body: some View {
        if managesPackages {
            selector.modifier(SkinPackageActionDialogs(model: packageActions))
        } else {
            selector
        }
    }

    private var selector: some View {
        let selectionAccentColor = presentationStyle.skinSelectionAccent(themeStore)

        return HorizontalFadeScrollContainer(
            spacing: itemSpacing,
            fadeWidth: presentationStyle.scaled(12),
            verticalPadding: verticalPadding,
            leadingScrollPadding: edgePadding,
            trailingScrollPadding: edgePadding,
            showsEdgeFade: true,
            showsScrollButtons: showsScrollButtons,
            scrollButtonLeadingInset: max(
                presentationStyle.scaled(4),
                edgePadding - presentationStyle.scaled(4)
            ),
            scrollButtonTrailingInset: max(
                presentationStyle.scaled(4),
                edgePadding - presentationStyle.scaled(4)
            )
        ) {
            ForEach(skins) { skin in
                let selected = selectedSkinID == skin.id
                let drawn = skinDrawnPreviewIDs.contains(skin.id)
                let card = SkinPreviewCard(
                    title: skin.name,
                    isSelected: selected,
                    sidebar: skin.sidebar,
                    previewFillsSquare: !drawn,
                    cardSize: cardSize,
                    previewSize: previewSize,
                    cornerRadius: cornerRadius,
                    titleFontSize: titleFontSize,
                    preview: {
                        if drawn {
                            skinPreview(
                                for: skin.id,
                                isSelected: selected,
                                accentColor: selectionAccentColor
                            )
                        } else {
                            SkinPackagePreviewView(
                                skinID: skin.id,
                                surface: surface,
                                foreground: previewForeground,
                                accent: selectionAccentColor
                            )
                        }
                    },
                    action: { selectedSkinID = skin.id }
                )
                if managesPackages && skin.isCustomPackage {
                    card.contextMenuWithVisibleIcons {
                        SkinPackageCardMenu(skinID: skin.id, model: packageActions)
                    }
                } else {
                    card
                }
            }
            if managesPackages {
                SkinPackageAddCard(
                    model: packageActions,
                    cardWidth: cardSize.width,
                    cornerRadius: cornerRadius,
                    titleFontSize: titleFontSize
                )
            }
        }
    }
}
