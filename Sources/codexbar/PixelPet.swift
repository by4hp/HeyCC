import SwiftUI

/// 小精灵的心情，由额度紧张程度决定。
enum PetMood: Sendable {
    case idle
    case worried
}

/// 像素风格的小精灵 —— CodexBar 的吉祥物。
/// 暖橙色调呼应 Claude；平时浮动眨眼、偶尔冒星星；额度告急时会冒汗发愁。
/// 交互：鼠标悬停会凑近放大；点一下会咧嘴笑、开心地蹦起来并四下迸星星。
struct PixelPet: View {
    /// 单个像素格的边长，整体为 16×16 格。
    var pixel: CGFloat = 3
    /// 心情：额度紧张时传 .worried，小精灵会发愁。
    var mood: PetMood = .idle
    /// 被戳时的回调（面板里接到这里刷新俏皮总结）。
    var onPoke: (() -> Void)?

    @State private var pokeTime: Date?
    @State private var hovering = false

    /// 睁眼帧。`.`=透明 `X`=描边 `+`=高光 `o`=身体 `e`=眼睛 `s`=眼神光 `c`=腮红 `d`=汗珠。
    private static let openFrame: [String] = [
        "......XXXX......",
        "....XX++++XX....",
        "...X++++++++X...",
        "..X++++++++++X..",
        "..X+++oooo+++X..",
        ".X++oooooooo++X.",
        ".X+oooooooooo+X.",
        ".X+ooseooseoo+X.",
        ".X+ooeeooeeoo+X.",
        ".X+ocooooooco+X.",
        ".X+oooooooooo+X.",
        "..X+oooooooo+X..",
        "..X++oooooo++X..",
        "...X++++++++X...",
        "....XX++++XX....",
        "......XXXX......",
    ]

    /// 眨眼帧：去掉上排眼睛，只剩一行。
    private static let blinkFrame: [String] = {
        var frame = openFrame
        frame[7] = ".X+oooooooooo+X."
        return frame
    }()

    /// 开心帧：眯眼 + 一张小嘴。
    private static let happyFrame: [String] = {
        var frame = openFrame
        frame[7] = ".X+oooooooooo+X."
        frame[10] = ".X+ooooeeoooo+X."
        return frame
    }()

    /// 发愁帧：冒一滴汗 + 小小的担心嘴。
    private static let worriedFrame: [String] = {
        var frame = openFrame
        frame[5] = ".X++oooooooo+dX."
        frame[11] = "..X+oooeeooo+X.."
        return frame
    }()

    private static let starColor = Color(red: 1, green: 0.84, blue: 0.42)

    var body: some View {
        let box = pixel * 20 // side(16) + 留白(4)
        return TimelineView(.animation) { context in
            petContent(at: context.date)
        }
        .frame(width: box, height: box)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            pokeTime = Date()
            onPoke?()
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: hovering)
        .help("戳我一下～")
    }

    /// 某一帧时刻的整只小精灵（精灵本体 + 星星）。
    private func petContent(at now: Date) -> some View {
        let side = pixel * 16
        let box = pixel * 20
        let time = now.timeIntervalSinceReferenceDate
        let react = reaction(at: now)
        let bob = sin(time * 2.3) * 1.6 - react * 9 // 被戳往上蹦
        let stretch = 1 + 0.05 * sin(time * 2.3 + .pi / 2) + react * 0.18

        return ZStack {
            sprite(currentFrame(react: react, time: time), side: side)
                .scaleEffect(x: 2 - stretch, y: stretch, anchor: .bottom)
            idleStar(side: side, opacity: react > 0.05 ? 0 : sparkle(at: time))
            burstStars(react: react, side: side)
        }
        .frame(width: box, height: box)
        .scaleEffect(hovering ? 1.12 : 1.0)
        .offset(y: bob)
    }

    /// 把字符网格画成像素精灵。
    private func sprite(_ frame: [String], side: CGFloat) -> some View {
        Canvas { ctx, _ in
            for (row, line) in frame.enumerated() {
                for (col, char) in line.enumerated() {
                    guard let color = Self.color(for: char) else { continue }
                    ctx.fill(
                        Path(CGRect(
                            x: CGFloat(col) * pixel, y: CGFloat(row) * pixel,
                            width: pixel, height: pixel)),
                        with: .color(color))
                }
            }
        }
        .frame(width: side, height: side)
    }

    /// 平时偶尔冒的一颗小星星。
    private func idleStar(side: CGFloat, opacity: Double) -> some View {
        Text("✦")
            .font(.system(size: pixel * 2.4))
            .foregroundStyle(Self.starColor)
            .opacity(opacity)
            .offset(x: side * 0.40, y: -side * 0.34)
    }

    /// 被戳时四下迸出的星星。
    private func burstStars(react: Double, side: CGFloat) -> some View {
        ForEach(0 ..< 5, id: \.self) { index in
            burstStar(index: index, react: react, side: side)
        }
    }

    private func burstStar(index: Int, react: Double, side: CGFloat) -> some View {
        let angle = Double(index) / 5 * 2 * .pi - .pi / 2
        let distance = side * (0.30 + 0.42 * react)
        let size = pixel * (1.4 + 0.5 * Double(index % 3))
        return Text("✦")
            .font(.system(size: size))
            .foregroundStyle(Self.starColor)
            .opacity(react * 0.9)
            .offset(x: cos(angle) * distance, y: sin(angle) * distance - side * 0.05)
    }

    /// 按反应/心情/眨眼挑选当前帧。
    private func currentFrame(react: Double, time: Double) -> [String] {
        if react > 0.05 { return Self.happyFrame }
        if mood == .worried { return Self.worriedFrame } // 发愁时盯着不眨眼
        return isBlinking(at: time) ? Self.blinkFrame : Self.openFrame
    }

    /// 被戳后 0.7 秒内的反应强度，正弦 0→1→0。
    private func reaction(at now: Date) -> Double {
        guard let pokeTime else { return 0 }
        let elapsed = now.timeIntervalSince(pokeTime)
        let duration = 0.7
        guard elapsed >= 0, elapsed <= duration else { return 0 }
        return sin(elapsed / duration * .pi)
    }

    /// 每 3.6 秒眨一次，持续约 0.16 秒。
    private func isBlinking(at time: Double) -> Bool {
        let cycle = 3.6
        return time.truncatingRemainder(dividingBy: cycle) > cycle - 0.16
    }

    /// 每 5.2 秒在最后 1.1 秒里淡入淡出一颗小星星。
    private func sparkle(at time: Double) -> Double {
        let cycle = 5.2
        let phase = time.truncatingRemainder(dividingBy: cycle)
        guard phase > cycle - 1.1 else { return 0 }
        return sin((phase - (cycle - 1.1)) / 1.1 * .pi) * 0.95
    }

    private static func color(for char: Character) -> Color? {
        switch char {
        case "X": return Color(red: 0.30, green: 0.19, blue: 0.13)
        case "+": return Color(red: 0.97, green: 0.78, blue: 0.62)
        case "o": return Color(red: 0.87, green: 0.49, blue: 0.34)
        case "e": return Color(red: 0.20, green: 0.13, blue: 0.11)
        case "s": return Color.white
        case "c": return Color(red: 0.96, green: 0.60, blue: 0.52)
        case "d": return Color(red: 0.56, green: 0.80, blue: 0.96) // 汗珠
        default: return nil
        }
    }
}
