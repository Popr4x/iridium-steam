import Foundation

@main enum LaunchOptionsCheck {
    static func main() {
        for option in MadeiraResolution.allCases {
            precondition(option.rawValue * 9 == option.height * 16)
            precondition(option.size.width == Double(option.rawValue))
            precondition(option.size.height == Double(option.height))
        }
        precondition(MadeiraResolution(rawValue: 0) == nil)
        print("Resolution dimensions passed")
    }
}
