import SwiftUI
import UIKit

struct ProfilePhotoCropper: View {
    let image: UIImage
    let onCancel: () -> Void
    let onUsePhoto: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cropSide: CGFloat = 0
    @State private var steadyScale: CGFloat = 1
    @State private var scaleAtGestureStart: CGFloat = 1
    @State private var steadyOffset: CGSize = .zero
    @State private var offsetAtGestureStart: CGSize = .zero

    init(image: UIImage, onCancel: @escaping () -> Void, onUsePhoto: @escaping (Data) -> Void) {
        self.image = Self.normalized(image)
        self.onCancel = onCancel
        self.onUsePhoto = onUsePhoto
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Drag to position and pinch to zoom")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    let baseScale = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
                    let displayedWidth = image.size.width * baseScale * steadyScale
                    let displayedHeight = image.size.height * baseScale * steadyScale

                    ZStack {
                        Color.black.opacity(0.85)
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: displayedWidth, height: displayedHeight)
                            .offset(steadyOffset)

                        CropAlignmentGrid()
                            .stroke(.white.opacity(0.68), lineWidth: 0.8)
                            .allowsHitTesting(false)
                    }
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.78), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .onAppear {
                        cropSide = side
                        steadyOffset = clampedOffset(
                            steadyOffset,
                            displayedWidth: displayedWidth,
                            displayedHeight: displayedHeight,
                            cropSide: side
                        )
                        offsetAtGestureStart = steadyOffset
                    }
                    .onChange(of: geometry.size) { _ in
                        cropSide = side
                        steadyOffset = clampedOffset(
                            steadyOffset,
                            displayedWidth: displayedWidth,
                            displayedHeight: displayedHeight,
                            cropSide: side
                        )
                        offsetAtGestureStart = steadyOffset
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                steadyOffset = clampedOffset(
                                    CGSize(
                                        width: offsetAtGestureStart.width + value.translation.width,
                                        height: offsetAtGestureStart.height + value.translation.height
                                    ),
                                    displayedWidth: displayedWidth,
                                    displayedHeight: displayedHeight,
                                    cropSide: side
                                )
                            }
                            .onEnded { _ in offsetAtGestureStart = steadyOffset }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                steadyScale = min(max(scaleAtGestureStart * value, 1), 4)
                                let scaledWidth = image.size.width * baseScale * steadyScale
                                let scaledHeight = image.size.height * baseScale * steadyScale
                                steadyOffset = clampedOffset(
                                    steadyOffset,
                                    displayedWidth: scaledWidth,
                                    displayedHeight: scaledHeight,
                                    cropSide: side
                                )
                            }
                            .onEnded { _ in
                                scaleAtGestureStart = steadyScale
                                offsetAtGestureStart = steadyOffset
                            }
                    )
                }
                .aspectRatio(1, contentMode: .fit)

                Button("Reset Position") { resetCrop() }
                    .font(.subheadline.weight(.medium))
                    .disabled(steadyScale == 1 && steadyOffset == .zero)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .navigationTitle("Adjust Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Photo") {
                        let data = croppedJPEG(side: cropSide)
                        onUsePhoto(data)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(cropSide <= 0)
                }
            }
        }
        .tint(.accentColor)
    }

    private func clampedOffset(
        _ proposed: CGSize,
        displayedWidth: CGFloat,
        displayedHeight: CGFloat,
        cropSide: CGFloat
    ) -> CGSize {
        let horizontalLimit = max(0, (displayedWidth - cropSide) / 2)
        let verticalLimit = max(0, (displayedHeight - cropSide) / 2)
        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposed.height, -verticalLimit), verticalLimit)
        )
    }

    private func resetCrop() {
        steadyScale = 1
        scaleAtGestureStart = 1
        steadyOffset = .zero
        offsetAtGestureStart = .zero
    }

    private func croppedJPEG(side: CGFloat) -> Data {
        let frameSide = max(side, 1)
        let imageWidth = max(image.size.width, 1)
        let imageHeight = max(image.size.height, 1)
        let baseScale = max(frameSide / imageWidth, frameSide / imageHeight)
        let outputScale = 512 / frameSide
        let displayedWidth = imageWidth * baseScale * steadyScale
        let displayedHeight = imageHeight * baseScale * steadyScale
        let exactOffset = clampedOffset(
            steadyOffset,
            displayedWidth: displayedWidth,
            displayedHeight: displayedHeight,
            cropSide: frameSide
        )
        let imageOrigin = CGPoint(
            x: (frameSide - displayedWidth) / 2 + exactOffset.width,
            y: (frameSide - displayedHeight) / 2 + exactOffset.height
        )
        let destination = CGRect(
            x: imageOrigin.x * outputScale,
            y: imageOrigin.y * outputScale,
            width: displayedWidth * outputScale,
            height: displayedHeight * outputScale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format)
        let croppedImage = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            image.draw(in: destination)
        }
        if let jpegData = croppedImage.jpegData(compressionQuality: 0.88) { return jpegData }
        if let uncroppedJPEG = image.jpegData(compressionQuality: 0.88) { return uncroppedJPEG }

        // UIGraphicsImageRenderer always produces a JPEG Data value, giving Use Photo
        // a non-nil fallback even if UIImage.jpegData cannot encode the source image.
        return renderer.jpegData(withCompressionQuality: 0.88) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            let fitScale = min(512 / imageWidth, 512 / imageHeight)
            let fitSize = CGSize(width: imageWidth * fitScale, height: imageHeight * fitScale)
            image.draw(in: CGRect(
                x: (512 - fitSize.width) / 2,
                y: (512 - fitSize.height) / 2,
                width: fitSize.width,
                height: fitSize.height
            ))
        }
    }

    private static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

private struct CropAlignmentGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for division in 1...2 {
            let fraction = CGFloat(division) / 3
            path.move(to: CGPoint(x: rect.width * fraction, y: 0))
            path.addLine(to: CGPoint(x: rect.width * fraction, y: rect.height))
            path.move(to: CGPoint(x: 0, y: rect.height * fraction))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height * fraction))
        }
        return path
    }
}
