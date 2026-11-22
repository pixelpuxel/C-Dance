import SwiftUI
import UIKit

struct MarkStroke: Identifiable, Sendable {
    enum Tool: Sendable { case pen, rectangle, ellipse, arrow }
    enum MarkColor: String, CaseIterable, Sendable {
        case red, green, blue, yellow

        var color: Color {
            switch self {
            case .red: .red
            case .green: .green
            case .blue: .blue
            case .yellow: .yellow
            }
        }

        var uiColor: UIColor {
            switch self {
            case .red: .systemRed
            case .green: .systemGreen
            case .blue: .systemBlue
            case .yellow: .systemYellow
            }
        }

        var title: String {
            switch self {
            case .red: "Rot"
            case .green: "Grün"
            case .blue: "Blau"
            case .yellow: "Gelb"
            }
        }
    }

    let id = UUID()
    let tool: Tool
    let color: MarkColor
    var points: [CGPoint]
}

enum MarkupRenderer {
    static func render(image: UIImage, strokes: [MarkStroke], canvasSize: CGSize) -> UIImage? {
        guard canvasSize.width > 0, canvasSize.height > 0, image.size.width > 0, image.size.height > 0 else { return nil }
        let outputScale = min(1, 4_096 / max(image.size.width, image.size.height))
        let outputSize = CGSize(
            width: max(1, (image.size.width * outputScale).rounded()),
            height: max(1, (image.size.height * outputScale).rounded())
        )
        let scaleX = outputSize.width / canvasSize.width
        let scaleY = outputSize.height / canvasSize.height
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        return renderer.image { rendererContext in
            UIColor.white.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: outputSize))
            image.draw(in: CGRect(origin: .zero, size: outputSize))
            let context = rendererContext.cgContext
            context.setLineWidth(max(5 * min(scaleX, scaleY), 8))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for stroke in strokes {
                let points = stroke.points.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }
                guard let first = points.first, let last = points.last else { continue }
                context.setStrokeColor(stroke.color.uiColor.cgColor)
                context.beginPath()
                switch stroke.tool {
                case .pen:
                    context.move(to: first)
                    points.dropFirst().forEach { context.addLine(to: $0) }
                case .rectangle:
                    context.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
                case .ellipse:
                    context.addEllipse(in: CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
                case .arrow:
                    context.move(to: first)
                    context.addLine(to: last)
                    let angle = atan2(last.y - first.y, last.x - first.x)
                    let arrowLength = 35 * min(scaleX, scaleY)
                    context.move(to: last)
                    context.addLine(to: CGPoint(x: last.x - arrowLength * cos(angle - 0.5), y: last.y - arrowLength * sin(angle - 0.5)))
                    context.move(to: last)
                    context.addLine(to: CGPoint(x: last.x - arrowLength * cos(angle + 0.5), y: last.y - arrowLength * sin(angle + 0.5)))
                }
                context.strokePath()
            }
        }
    }
}

enum CropRenderer {
    static func crop(image: UIImage, canvasSize: CGSize, zoom: CGFloat, offset: CGSize, cropRect: CGRect, contentInset: CGFloat = 0) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0,
              canvasSize.width > 0, canvasSize.height > 0,
              cropRect.width > 0, cropRect.height > 0 else { return nil }

        // Full-resolution iPhone photos can exceed 40 MP. Normalizing such an
        // image at its original size creates another very large bitmap and can
        // terminate the app under memory pressure. Cropping does not need more
        // than the resolution accepted by the generator.
        let normalizationScale = min(1, 4_096 / max(image.size.width, image.size.height))
        let normalizedSize = CGSize(
            width: max(1, (image.size.width * normalizationScale).rounded()),
            height: max(1, (image.size.height * normalizationScale).rounded())
        )
        let normalized: UIImage
        if image.imageOrientation == .up, normalizationScale == 1, let source = image.cgImage {
            normalized = UIImage(cgImage: source, scale: 1, orientation: .up)
        } else {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            normalized = UIGraphicsImageRenderer(size: normalizedSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: normalizedSize))
            }
        }
        guard let source = normalized.cgImage else { return nil }

        let availableSize = CGSize(
            width: max(1, canvasSize.width - contentInset * 2),
            height: max(1, canvasSize.height - contentInset * 2)
        )
        let baseScale = min(availableSize.width / normalized.size.width, availableSize.height / normalized.size.height)
        let effectiveScale = baseScale * max(1, zoom)
        let displayedSize = CGSize(width: normalized.size.width * effectiveScale, height: normalized.size.height * effectiveScale)
        let imageOrigin = CGPoint(
            x: (canvasSize.width - displayedSize.width) / 2 + offset.width,
            y: (canvasSize.height - displayedSize.height) / 2 + offset.height
        )
        let cropRect = CGRect(
            x: (cropRect.minX - imageOrigin.x) / effectiveScale,
            y: (cropRect.minY - imageOrigin.y) / effectiveScale,
            width: cropRect.width / effectiveScale,
            height: cropRect.height / effectiveScale
        ).integral.intersection(CGRect(origin: .zero, size: normalized.size))
        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = source.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}

enum CropHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var accessibilityName: String {
        switch self {
        case .topLeft: "Ecke oben links"
        case .top: "Kante oben"
        case .topRight: "Ecke oben rechts"
        case .right: "Kante rechts"
        case .bottomRight: "Ecke unten rechts"
        case .bottom: "Kante unten"
        case .bottomLeft: "Ecke unten links"
        case .left: "Kante links"
        }
    }
}

enum CropInteractionGeometry {
    static func closestHandle(
        to point: CGPoint,
        in rect: CGRect,
        maximumDistance: CGFloat
    ) -> CropHandle? {
        let corners: [CropHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        let cornerCandidates: [(handle: CropHandle, distance: CGFloat)] = corners
            .map { handle in
                let position = handlePosition(handle, in: rect)
                return (handle: handle, distance: hypot(point.x - position.x, point.y - position.y))
            }
        if let corner = cornerCandidates
            .filter({ $0.distance <= maximumDistance })
            .min(by: { $0.distance < $1.distance })?
            .handle {
            return corner
        }

        // The complete border is draggable, not just the small visual grip in
        // its centre. Keep corners preferable so diagonal resizing remains
        // predictable where the hit regions meet.
        let edgeTolerance = min(maximumDistance, 36)
        let withinHorizontalSpan = point.x >= rect.minX - edgeTolerance && point.x <= rect.maxX + edgeTolerance
        let withinVerticalSpan = point.y >= rect.minY - edgeTolerance && point.y <= rect.maxY + edgeTolerance
        let edges: [(handle: CropHandle, distance: CGFloat, inSpan: Bool)] = [
            (handle: .top, distance: abs(point.y - rect.minY), inSpan: withinHorizontalSpan),
            (handle: .right, distance: abs(point.x - rect.maxX), inSpan: withinVerticalSpan),
            (handle: .bottom, distance: abs(point.y - rect.maxY), inSpan: withinHorizontalSpan),
            (handle: .left, distance: abs(point.x - rect.minX), inSpan: withinVerticalSpan),
        ]
        return edges
            .filter { $0.inSpan && $0.distance <= edgeTolerance }
            .min { $0.distance < $1.distance }?
            .handle
    }

    static func handlePosition(_ handle: CropHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    static func adjustedRect(
        _ source: CGRect,
        handle: CropHandle,
        translation: CGSize,
        bounds: CGRect,
        minimumLength: CGFloat
    ) -> CGRect {
        var minimumX = source.minX
        var maximumX = source.maxX
        var minimumY = source.minY
        var maximumY = source.maxY

        if [.topLeft, .left, .bottomLeft].contains(handle) {
            minimumX = min(max(source.minX + translation.width, bounds.minX), source.maxX - minimumLength)
        }
        if [.topRight, .right, .bottomRight].contains(handle) {
            maximumX = max(min(source.maxX + translation.width, bounds.maxX), source.minX + minimumLength)
        }
        if [.topLeft, .top, .topRight].contains(handle) {
            minimumY = min(max(source.minY + translation.height, bounds.minY), source.maxY - minimumLength)
        }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) {
            maximumY = max(min(source.maxY + translation.height, bounds.maxY), source.minY + minimumLength)
        }
        return CGRect(x: minimumX, y: minimumY, width: maximumX - minimumX, height: maximumY - minimumY)
    }
}

struct MarkupEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage
    @State private var strokes: [MarkStroke] = []
    @State private var current: MarkStroke?
    @State private var tool: MarkStroke.Tool = .pen
    @State private var markColor: MarkStroke.MarkColor = .red
    @State private var instruction = ""
    @State private var canvasSize: CGSize = .zero
    @State private var imageWasChanged = false
    @State private var previousImages: [UIImage] = []
    @State private var isApplying = false
    @State private var showsCropper = false
    @FocusState private var instructionFocused: Bool
    let onDone: (Data, String) -> Void
    init(image: UIImage, onDone: @escaping (Data,String)->Void) { _image=State(initialValue:image);self.onDone=onDone }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Werkzeug",selection:$tool){Text("Stift").tag(MarkStroke.Tool.pen);Text("Rechteck").tag(MarkStroke.Tool.rectangle);Text("Kreis").tag(MarkStroke.Tool.ellipse);Text("Pfeil").tag(MarkStroke.Tool.arrow)}
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                HStack(spacing: 14) {
                    Text("Farbe").font(.subheadline.weight(.semibold))
                    ForEach(MarkStroke.MarkColor.allCases, id: \.self) { color in
                        Button {
                            markColor = color
                        } label: {
                            Circle()
                                .fill(color.color)
                                .frame(width: 26, height: 26)
                                .overlay {
                                    Circle().stroke(.primary, lineWidth: markColor == color ? 3 : 0)
                                }
                                .padding(5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(color.title)
                        .accessibilityAddTraits(markColor == color ? .isSelected : [])
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                GeometryReader { proxy in
                    let fit = fitted(image.size, in: proxy.size)
                    ZStack {
                        Image(uiImage:image).resizable().scaledToFit().background(.white)
                        Canvas { context,_ in strokes.forEach{draw($0,in:&context)};if let current{draw(current,in:&context)} }
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance:0).onChanged{value in if current==nil{current=MarkStroke(tool:tool,color:markColor,points:[value.startLocation])};if tool == .pen{current?.points.append(value.location)}else if current?.points.count == 1{current?.points.append(value.location)}else{current?.points[current!.points.count-1]=value.location} }.onEnded{_ in if let current{strokes.append(current)};current=nil})
                    }.frame(width:fit.width,height:fit.height).position(x:proxy.size.width/2,y:proxy.size.height/2).onAppear{canvasSize=fit}.onChange(of:fit){_,n in canvasSize=n}
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Menu { Button("Links +25 %"){expand(.left)};Button("Rechts +25 %"){expand(.right)};Button("Oben +25 %"){expand(.top)};Button("Unten +25 %"){expand(.bottom)} } label: { Label("Canvas", systemImage:"arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.bordered)
                        Button { showsCropper = true } label: { Label("Zuschneiden", systemImage: "crop") }
                            .buttonStyle(.bordered)
                        Menu { ForEach(["1:1","4:3","3:4","16:9","9:16"],id:\.self){ratio in Button(ratio){fitRatio(ratio)}} } label: { Label("Format", systemImage:"aspectratio") }
                        .buttonStyle(.bordered)
                        Button { undoLastChange() } label: { Label("Rückgängig", systemImage:"arrow.uturn.backward") }
                            .buttonStyle(.bordered)
                            .disabled(strokes.isEmpty && previousImages.isEmpty)
                        Button(role:.destructive) { strokes=[] } label: { Label("Leeren", systemImage:"trash") }.buttonStyle(.bordered).disabled(strokes.isEmpty)
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                }
                VStack(alignment:.leading,spacing:6) {
                    Text("Änderungsanweisung").font(.subheadline.weight(.semibold))
                    TextField("Was soll im markierten Bereich geändert werden?",text:$instruction,axis:.vertical)
                        .lineLimit(2...5).focused($instructionFocused)
                        .padding(12).background(Color(uiColor:.tertiarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:12))
                }.padding(.horizontal,16).padding(.bottom,12)
            }
            .background(CDanceTheme.background)
            .navigationTitle("Bild bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsCropper) {
                ImageCropperView(image: image) { cropped in
                    previousImages.append(image)
                    image = cropped
                    imageWasChanged = true
                    strokes = []
                }
            }
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button("Abbrechen"){dismiss()}}
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        apply()
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Übernehmen").bold()
                        }
                    }
                    .disabled(!canApply || isApplying)
                    .accessibilityLabel(isApplying ? "Markierung wird übernommen" : "Übernehmen")
                }
                ToolbarItemGroup(placement:.keyboard){Spacer();Button("Fertig"){instructionFocused=false}}
            }
        }
    }

    private func draw(_ stroke: MarkStroke, in context: inout GraphicsContext) {
        guard let first = stroke.points.first, let last = stroke.points.last else { return }
        var path = Path()
        switch stroke.tool {
        case .pen:
            path.move(to: first); for point in stroke.points.dropFirst() { path.addLine(to: point) }
        case .rectangle:
            path.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
        case .ellipse:
            path.addEllipse(in: CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
        case .arrow:
            path.move(to: first); path.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            path.move(to: last); path.addLine(to: CGPoint(x: last.x - 22 * cos(angle - 0.5), y: last.y - 22 * sin(angle - 0.5)))
            path.move(to: last); path.addLine(to: CGPoint(x: last.x - 22 * cos(angle + 0.5), y: last.y - 22 * sin(angle + 0.5)))
        }
        context.stroke(path, with: .color(stroke.color.color), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
    }
    private func render() -> UIImage? {
        MarkupRenderer.render(image: image, strokes: strokes, canvasSize: canvasSize)
    }
    private func apply() {
        let sourceImage = image
        let completedStrokes = strokes
        let completedCanvasSize = canvasSize
        let completedInstruction = instruction
        isApplying = true
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    MarkupRenderer.render(
                        image: sourceImage,
                        strokes: completedStrokes,
                        canvasSize: completedCanvasSize
                    )?.jpegData(compressionQuality: 0.94)
                }
            }.value
            isApplying = false
            guard let data else { return }
            onDone(data, completedInstruction)
            dismiss()
        }
    }
    private var canApply: Bool {
        imageWasChanged || !strokes.isEmpty || !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private enum Side{case left,right,top,bottom}
    private func undoLastChange() {
        if !strokes.isEmpty {
            _ = strokes.popLast()
        } else if let previous = previousImages.popLast() {
            image = previous
            imageWasChanged = !previousImages.isEmpty
        }
    }
    private func expand(_ side: Side) {
        let horizontal = side == .left || side == .right
        let vertical = side == .top || side == .bottom
        let delta = (horizontal ? image.size.width : image.size.height) * 0.25
        let size = CGSize(width: image.size.width + (horizontal ? delta : 0), height: image.size.height + (vertical ? delta : 0))
        let renderer = UIGraphicsImageRenderer(size: size)
        image = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            image.draw(at: CGPoint(x: side == .left ? delta : 0, y: side == .top ? delta : 0))
        }
        imageWasChanged = true
        strokes = []
    }
    private func fitRatio(_ value:String){let p=value.split(separator:":").compactMap{Double($0)};guard p.count==2 else{return};let target=p[0]/p[1],current=image.size.width/image.size.height;var size=image.size;if current<target{size.width=image.size.height*target}else{size.height=image.size.width/target};let renderer=UIGraphicsImageRenderer(size:size);image=renderer.image{ctx in UIColor.white.setFill();ctx.fill(CGRect(origin:.zero,size:size));image.draw(at:CGPoint(x:(size.width-image.size.width)/2,y:(size.height-image.size.height)/2))};imageWasChanged=true;strokes=[]}
    private func fitted(_ source:CGSize,in container:CGSize)->CGSize{let s=min(container.width/source.width,container.height/source.height);return CGSize(width:source.width*s,height:source.height*s)}
}

private struct ImageCropperView: View {
    private enum Aspect: String, CaseIterable, Identifiable {
        case free = "Frei"
        case original = "Original"
        case square = "1:1"
        case landscape = "4:3"
        case portrait = "3:4"
        case wide = "16:9"
        case tall = "9:16"

        var id: Self { self }
        func ratio(for image: UIImage) -> CGFloat? {
            switch self {
            case .free: nil
            case .original: image.size.width / image.size.height
            case .square: 1
            case .landscape: 4 / 3
            case .portrait: 3 / 4
            case .wide: 16 / 9
            case .tall: 9 / 16
            }
        }
    }

    private struct Snapshot {
        let cropRect: CGRect
        let zoom: CGFloat
        let offset: CGSize
        let aspect: Aspect
    }

    private struct DragContext {
        enum Target {
            case handle(CropHandle)
            case image
        }

        let target: Target
        let snapshot: Snapshot
    }

    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let onDone: (UIImage) -> Void
    @State private var aspect: Aspect = .free
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var canvasSize: CGSize = .zero
    @State private var cropRect: CGRect = .zero
    @State private var history: [Snapshot] = []
    @State private var dragContext: DragContext?
    @State private var isApplying = false
    @GestureState private var gestureZoom: CGFloat = 1

    private let minimumCropLength: CGFloat = 64
    private let imageInset: CGFloat = 16
    private let handleTouchRadius: CGFloat = 54
    private let initialHandleInset: CGFloat = 34

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text("Ecken oder Kanten ziehen. Mit zwei Fingern zoomen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                GeometryReader { proxy in
                    let size = proxy.size
                    let effectiveZoom = min(max(zoom * gestureZoom, 1), 8)
                    let effectiveOffset = clampedOffset(offset, zoom: effectiveZoom, canvas: size, crop: cropRect)
                    let displaySize = displayedImageSize(zoom: effectiveZoom, canvas: size)

                    ZStack(alignment: .topLeading) {
                        Color.black
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: displaySize.width, height: displaySize.height)
                            .position(
                                x: size.width / 2 + effectiveOffset.width,
                                y: size.height / 2 + effectiveOffset.height
                            )

                        if cropRect != .zero {
                            Rectangle()
                                .stroke(.white, lineWidth: 2)
                                .frame(width: cropRect.width, height: cropRect.height)
                                .position(x: cropRect.midX, y: cropRect.midY)
                                .allowsHitTesting(false)

                            ForEach(CropHandle.allCases, id: \.self) { handle in
                                cropHandle(handle)
                            }
                        }

                        // A single hit surface decides at touch-down whether
                        // the user grabbed the nearest handle or the image.
                        // This avoids overlapping SwiftUI gestures stealing
                        // the top, right and bottom handles.
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .gesture(cropDragGesture(canvas: size, zoom: effectiveZoom))
                            .simultaneousGesture(zoomGesture(canvas: size))
                            .zIndex(20)
                    }
                    .clipped()
                    .onAppear { configureCanvas(size) }
                    .onChange(of: size) { _, newSize in configureCanvas(newSize) }
                }

                HStack(spacing: 10) {
                    Button { undo() } label: {
                        Label("Rückgängig", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .disabled(history.isEmpty)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Aspect.allCases) { choice in
                                Button(choice.rawValue) { applyAspect(choice) }
                                    .buttonStyle(.bordered)
                                    .tint(aspect == choice ? CDanceTheme.accent : nil)
                                    .accessibilityAddTraits(aspect == choice ? .isSelected : [])
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
            .background(CDanceTheme.background)
            .navigationTitle("Ausschnitt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { applyCrop() } label: {
                        if isApplying { ProgressView().controlSize(.small) }
                        else { Text("Übernehmen").bold() }
                    }
                    .disabled(cropRect == .zero || isApplying)
                }
            }
        }
    }

    @ViewBuilder
    private func cropHandle(_ handle: CropHandle) -> some View {
        let edge = isEdge(handle)
        let position = CropInteractionGeometry.handlePosition(handle, in: cropRect)
        ZStack {
            if edge {
                Capsule().fill(.white).frame(width: handle == .top || handle == .bottom ? 34 : 9,
                                             height: handle == .top || handle == .bottom ? 9 : 34)
            } else {
                Circle().fill(.white).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(.black.opacity(0.7), lineWidth: 2))
            }
        }
        .position(position)
        .zIndex(10)
        .allowsHitTesting(false)
        .accessibilityLabel(handle.accessibilityName)
    }

    private func cropDragGesture(canvas: CGSize, zoom: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if dragContext == nil {
                    let snapshot = Snapshot(cropRect: cropRect, zoom: self.zoom, offset: offset, aspect: aspect)
                    let target = CropInteractionGeometry.closestHandle(
                        to: value.startLocation,
                        in: snapshot.cropRect,
                        maximumDistance: handleTouchRadius
                    ).map(DragContext.Target.handle) ?? .image
                    dragContext = DragContext(target: target, snapshot: snapshot)
                }
                guard let context = dragContext else { return }
                switch context.target {
                case .handle(let handle):
                    cropRect = CropInteractionGeometry.adjustedRect(
                        context.snapshot.cropRect,
                        handle: handle,
                        translation: value.translation,
                        bounds: displayedImageRect(zoom: zoom, offset: offset, canvas: canvas),
                        minimumLength: minimumCropLength
                    )
                    aspect = .free
                case .image:
                    offset = clampedOffset(
                        CGSize(
                            width: context.snapshot.offset.width + value.translation.width,
                            height: context.snapshot.offset.height + value.translation.height
                        ),
                        zoom: zoom,
                        canvas: canvas,
                        crop: cropRect
                    )
                }
            }
            .onEnded { _ in
                guard let context = dragContext else { return }
                history.append(context.snapshot)
                dragContext = nil
                offset = clampedOffset(offset, zoom: self.zoom, canvas: canvas, crop: cropRect)
            }
    }

    private func zoomGesture(canvas: CGSize) -> some Gesture {
        MagnificationGesture()
            .updating($gestureZoom) { value, state, _ in state = value }
            .onEnded { value in
                saveSnapshot()
                zoom = min(max(zoom * value, 1), 8)
                offset = clampedOffset(offset, zoom: zoom, canvas: canvas, crop: cropRect)
            }
    }

    private func configureCanvas(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let oldSize = canvasSize
        canvasSize = size
        if cropRect == .zero || oldSize == .zero {
            let imageRect = baseImageRect(canvas: size)
            let inset = min(initialHandleInset, max(2, min(imageRect.width, imageRect.height) / 5))
            cropRect = imageRect.insetBy(dx: inset, dy: inset)
        } else if oldSize != size {
            let scaleX = size.width / oldSize.width
            let scaleY = size.height / oldSize.height
            cropRect = CGRect(
                x: cropRect.minX * scaleX,
                y: cropRect.minY * scaleY,
                width: cropRect.width * scaleX,
                height: cropRect.height * scaleY
            ).intersection(baseImageRect(canvas: size))
            offset = clampedOffset(offset, zoom: zoom, canvas: size, crop: cropRect)
        }
    }

    private func applyAspect(_ choice: Aspect) {
        saveSnapshot()
        aspect = choice
        guard let ratio = choice.ratio(for: image) else { return }
        let bounds = displayedImageRect(zoom: zoom, offset: offset, canvas: canvasSize)
        var width = min(cropRect.width, bounds.width)
        var height = width / ratio
        if height > min(cropRect.height, bounds.height) {
            height = min(cropRect.height, bounds.height)
            width = height * ratio
        }
        let center = CGPoint(x: cropRect.midX, y: cropRect.midY)
        var proposed = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        if proposed.minX < bounds.minX { proposed.origin.x = bounds.minX }
        if proposed.maxX > bounds.maxX { proposed.origin.x = bounds.maxX - proposed.width }
        if proposed.minY < bounds.minY { proposed.origin.y = bounds.minY }
        if proposed.maxY > bounds.maxY { proposed.origin.y = bounds.maxY - proposed.height }
        cropRect = proposed
    }

    private func saveSnapshot() {
        guard cropRect != .zero else { return }
        history.append(Snapshot(cropRect: cropRect, zoom: zoom, offset: offset, aspect: aspect))
    }

    private func undo() {
        guard let snapshot = history.popLast() else { return }
        cropRect = snapshot.cropRect
        zoom = snapshot.zoom
        offset = snapshot.offset
        aspect = snapshot.aspect
    }

    private func isEdge(_ handle: CropHandle) -> Bool {
        [.top, .right, .bottom, .left].contains(handle)
    }

    private func baseImageRect(canvas: CGSize) -> CGRect {
        let display = displayedImageSize(zoom: 1, canvas: canvas)
        return CGRect(x: (canvas.width - display.width) / 2,
                      y: (canvas.height - display.height) / 2,
                      width: display.width,
                      height: display.height)
    }

    private func displayedImageSize(zoom: CGFloat, canvas: CGSize) -> CGSize {
        let available = CGSize(width: max(1, canvas.width - imageInset * 2),
                               height: max(1, canvas.height - imageInset * 2))
        let scale = min(available.width / image.size.width, available.height / image.size.height) * zoom
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func displayedImageRect(zoom: CGFloat, offset: CGSize, canvas: CGSize) -> CGRect {
        let display = displayedImageSize(zoom: zoom, canvas: canvas)
        return CGRect(x: (canvas.width - display.width) / 2 + offset.width,
                      y: (canvas.height - display.height) / 2 + offset.height,
                      width: display.width,
                      height: display.height)
    }

    private func clampedOffset(_ proposed: CGSize, zoom: CGFloat, canvas: CGSize, crop: CGRect) -> CGSize {
        guard crop != .zero else { return proposed }
        let display = displayedImageSize(zoom: zoom, canvas: canvas)
        let minimumX = crop.maxX - canvas.width / 2 - display.width / 2
        let maximumX = crop.minX - canvas.width / 2 + display.width / 2
        let minimumY = crop.maxY - canvas.height / 2 - display.height / 2
        let maximumY = crop.minY - canvas.height / 2 + display.height / 2
        return CGSize(width: min(max(proposed.width, minimumX), maximumX),
                      height: min(max(proposed.height, minimumY), maximumY))
    }

    private func applyCrop() {
        let source = image
        let outputCanvas = canvasSize
        let outputZoom = zoom
        let outputOffset = clampedOffset(offset, zoom: zoom, canvas: canvasSize, crop: cropRect)
        let outputCrop = cropRect
        let outputInset = imageInset
        isApplying = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    CropRenderer.crop(image: source, canvasSize: outputCanvas, zoom: outputZoom, offset: outputOffset, cropRect: outputCrop, contentInset: outputInset)
                }
            }.value
            isApplying = false
            guard let result else { return }
            onDone(result)
            dismiss()
        }
    }
}

#if DEBUG
struct CropFixtureView: View {
    private let fixture: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 1_200), format: format).image { context in
            let colors: [UIColor] = [.systemRed, .systemBlue, .systemGreen, .systemYellow]
            for row in 0..<2 {
                for column in 0..<2 {
                    colors[row * 2 + column].setFill()
                    context.fill(CGRect(x: column * 600, y: row * 600, width: 600, height: 600))
                }
            }
        }
    }()

    var body: some View {
        ImageCropperView(image: fixture) { _ in }
    }
}
#endif
