//
//  SkinPreviewCard.swift
//  myPlayer2
//
//  kmgccc_player - Reusable skin selection card with preview and title.
//

import MotionKit
import SwiftUI

/// A selectable card showing a square skin preview and its name.
/// Used in horizontal skin selectors for both window and fullscreen playback settings.
///
/// The preview sits inset by the same width on its leading, top and trailing edges, and its
/// corners are concentric with the card's, so the margin stays even around the curves too.
/// The card's height follows its width; a package may add a vertical side strip on the trailing
/// side with its own label at the top and the author's name at the bottom.
struct SkinPreviewCard<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let sidebar: SkinCardSidebarText?
    /// Package previews fill the square; the built-in drawings sit at `previewSize` in its centre.
    let previewFillsSquare: Bool
    let cardSize: CGSize
    let previewSize: CGFloat
    let cornerRadius: CGFloat
    let titleFontSize: CGFloat
    @ViewBuilder let preview: () -> Preview
    let action: () -> Void

    @State private var isHovering = false
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    private var selectionAccentColor: Color {
        FullscreenSelectionAccentStyle.adjustedAccentColor(from: themeStore.accentNSColor)
    }

    private var outerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var geometry: SkinCardGeometry {
        SkinCardGeometry(width: cardSize.width, cornerRadius: cornerRadius, titleFontSize: titleFontSize)
    }

    init(
        title: String,
        isSelected: Bool,
        sidebar: SkinCardSidebarText? = nil,
        previewFillsSquare: Bool = false,
        cardSize: CGSize = CGSize(width: 104, height: 124),
        previewSize: CGFloat = 80,
        cornerRadius: CGFloat = 12,
        titleFontSize: CGFloat = 11,
        @ViewBuilder preview: @escaping () -> Preview,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isSelected = isSelected
        self.sidebar = sidebar
        self.previewFillsSquare = previewFillsSquare
        self.cardSize = cardSize
        self.previewSize = previewSize
        self.cornerRadius = cornerRadius
        self.titleFontSize = titleFontSize
        self.preview = preview
        self.action = action
    }

    var body: some View {
        let geometry = geometry
        HStack(spacing: 0) {
            SkinCardLayout(geometry: geometry, title: title, titleFontSize: titleFontSize, titleColor: titleColor) {
                ZStack {
                    RoundedRectangle(cornerRadius: geometry.innerCornerRadius, style: .continuous)
                        .fill(previewSurfaceColor)
                    if previewFillsSquare {
                        preview()
                    } else {
                        preview()
                            .scaleEffect(presentationStyle.fullscreenScale)
                            .frame(width: previewSize, height: previewSize)
                    }
                }
            }
            .background(outerShape.fill(cardBackgroundColor))

            if let sidebar {
                sidebarStrip(sidebar, geometry: geometry)
            }
        }
        .frame(width: geometry.width + (sidebar == nil ? 0 : geometry.sidebarWidth), height: geometry.height)
        .background {
            if sidebar != nil {
                outerShape.fill(cardBackgroundColor.opacity(0.5))
            }
        }
        .clipShape(outerShape)
        .contentShape(outerShape)
        .opacity(isHovering ? 0.88 : 1.0)
        .motionAnimation(.microInteraction, value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: action)
    }

    /// Laid out as a horizontal row the length of the card, then turned a quarter clockwise,
    /// so the label reads downward from the top and the author ends at the bottom.
    private func sidebarStrip(_ sidebar: SkinCardSidebarText, geometry: SkinCardGeometry) -> some View {
        HStack(spacing: geometry.inset) {
            if let label = sidebar.label {
                Text(label)
                    .font(.system(size: titleFontSize, weight: .medium))
                    .foregroundStyle(titleColor.opacity(0.72))
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            if let author = sidebar.author {
                Text(author)
                    .font(.system(size: titleFontSize * 0.9))
                    .foregroundStyle(titleColor.opacity(0.48))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, geometry.inset)
        .frame(width: geometry.height, height: geometry.sidebarWidth)
        .rotationEffect(.degrees(90))
        .frame(width: geometry.sidebarWidth, height: geometry.height)
    }

    // MARK: - Appearance

    /// Selection is carried by fill alone: the whole card takes a stronger tint.
    private var previewSurfaceColor: Color {
        if presentationStyle.usesUnifiedOverlayForeground {
            return presentationStyle.primaryTextColor.opacity(isSelected ? 0.10 : 0.06)
        }
        if isSelected {
            return selectionAccentColor.opacity(0.14)
        }
        if let appColors {
            return appColors.secondary.opacity(0.08)
        }
        return colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }

    private var cardBackgroundColor: Color {
        if presentationStyle.usesUnifiedOverlayForeground {
            return presentationStyle.primaryTextColor.opacity(isSelected ? 0.20 : 0.045)
        }
        if isSelected {
            return selectionAccentColor.opacity(0.22)
        }
        if let appColors {
            return appColors.secondary.opacity(0.08)
        }
        return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    private var titleColor: Color {
        if presentationStyle.usesUnifiedOverlayForeground {
            return presentationStyle.skinTitleColor(
                selected: isSelected,
                accentColor: selectionAccentColor,
                colorScheme: colorScheme
            )
        }
        if isSelected {
            return selectionAccentColor
        }
        if let appColors {
            return appColors.secondary
        }
        return colorScheme == .dark ? Color.white.opacity(0.82) : Color.black.opacity(0.62)
    }
}

/// Shared metrics for skin cards: an even inset around a square preview, concentric corners,
/// and a title row below the preview.
struct SkinCardGeometry {
    let width: CGFloat
    let cornerRadius: CGFloat
    let titleFontSize: CGFloat

    var inset: CGFloat { cornerRadius / 2 }
    var innerCornerRadius: CGFloat { max(cornerRadius - inset, 0) }
    var previewSide: CGFloat { max(width - inset * 2, 0) }
    var titleRowHeight: CGFloat { ceil(titleFontSize * 1.3) + inset * 2 }
    var height: CGFloat { inset + previewSide + titleRowHeight }
    var sidebarWidth: CGFloat { ceil(titleFontSize * 1.3) + inset * 2 }
}

/// Places a square preview and a leading-aligned title in card geometry.
struct SkinCardLayout<Preview: View>: View {
    let geometry: SkinCardGeometry
    let title: String
    let titleFontSize: CGFloat
    let titleColor: Color
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview()
                .frame(width: geometry.previewSide, height: geometry.previewSide)
                .clipShape(RoundedRectangle(cornerRadius: geometry.innerCornerRadius, style: .continuous))

            Text(title)
                .font(.system(size: titleFontSize, weight: .medium))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: geometry.titleRowHeight)
        }
        .padding(.horizontal, geometry.inset)
        .padding(.top, geometry.inset)
        .frame(width: geometry.width, height: geometry.height, alignment: .top)
    }
}
