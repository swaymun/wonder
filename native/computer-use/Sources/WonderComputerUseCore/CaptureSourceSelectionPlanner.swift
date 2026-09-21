import Foundation

public enum CaptureSourceSelectionPlan: Equatable, Sendable {
    case select(sourceID: String)
    case presentDisplayPicker
    case unavailable(reason: String)
}

public enum CaptureSourceSelectionPlanner {
    public static func plan(
        requestedSourceID: String?,
        displayIDs: Set<UInt32>,
        sourceIDs: Set<String>,
        mainDisplayID: UInt32,
        pickerAvailable: Bool
    ) -> CaptureSourceSelectionPlan {
        if let requestedSourceID {
            guard sourceIDs.contains(requestedSourceID) else {
                return .unavailable(reason: "source_not_found")
            }
            return .select(sourceID: requestedSourceID)
        }

        let mainSourceID = "display:\(mainDisplayID)"
        if displayIDs.contains(mainDisplayID), sourceIDs.contains(mainSourceID) {
            return .select(sourceID: mainSourceID)
        }

        if pickerAvailable {
            return .presentDisplayPicker
        }
        return .unavailable(reason: "system_picker_unavailable")
    }
}
