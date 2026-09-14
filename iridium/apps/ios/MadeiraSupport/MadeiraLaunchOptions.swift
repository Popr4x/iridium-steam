import Foundation

enum MadeiraResolution: Int, CaseIterable {
    case low = 640, standard = 960, hd = 1280, fullHD = 1920
    static let key = "IridiumRenderWidth"
    static var selected: Self { Self(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .standard }
    var height: Int { rawValue * 9 / 16 }
    var title: String { "\(rawValue) × \(height)" }
    var size: CGSize { CGSize(width: Double(rawValue), height: Double(height)) }
}
