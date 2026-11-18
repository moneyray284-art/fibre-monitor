import SwiftUI
import UIKit

struct ProfilePhotoCropper: View {
    let image: UIImage
    let onCancel: () -> Void
    let onUsePhoto: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cropSide: CGFloat = 0
    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var panAtGestureStart: CGSize = .zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Drag to position and pinch to zoom")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    let baseScale = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
                    let displayedWidth = image.size.width * baseScale * zoom
                    let displayedHeight = image.size.height * baseScale * zoom

                    ZStack {
                        Color.black.opacity(0.85)
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: displayedWidth, height: displayedHeight)
                            .offset(panOffset)

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
                    .onAppear { cropSide = side }
                    .onChange(of: geometry.size) { _ in cropSide = side }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                panOffset = clampedOffset(
                                    CGSize(
                                        width: panAtGestureStart.width + value.translation.width,
                                        height: panAtGestureStart.height + value.translation.height
                                    ),
                                    displayedWidth: displayedWidth,
                                    displayedHeight: displayedHeight,
                                    cropSide: side
                                )
                            }
                            .onEnded { _ in panAtGestureStart = panOffset }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                zoom = min(max(zoomAtGestureStart * value, 1), 4)
                                let scaledWidth = image.size.width * baseScale * zoom
                                let scaledHeight = image.size.height * baseScale * zoom
                                panOffset = clampedOffset(
                                    panOffset,
                                    displayedWidth: scaledWidth,
                                    displayedHeight: scaledHeight,
                                    cropSide: side
                                )
                            }
                            .onEnded { _ in
                                zoomAtGestureStart = zoom
                                panAtGestureStart = panOffset
                            }
                    )
                }
                .aspectRatio(1, contentMode: .fit)

                Button("Reset Position") { resetCrop() }
                    .font(.subheadline.weight(.medium))
                    .disabled(zoom == 1 && panOffset == .zero)

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
                        guard let data = croppedJPEG(side: cropSide) else { return }
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
        zoom = 1
        zoomAtGestureStart = 1
        panOffset = .zero
        panAtGestureStart = .zero
    }

    private func croppedJPEG(side: CGFloat) -> Data? {
        guard side > 0, image.size.width > 0, image.size.height > 0 else { return nil }
        let baseScale = max(side / image.size.width, side / image.size.height)
        let outputScale = 512 / side
        let displayedWidth = image.size.width * baseScale * zoom
        let displayedHeight = image.size.height * baseScale * zoom
        let imageOrigin = CGPoint(
            x: (side - displayedWidth) / 2 + panOffset.width,
            y: (side - displayedHeight) / 2 + panOffset.height
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
        return renderer.image { _ in image.draw(in: destination) }.jpegData(compressionQuality: 0.9)
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
