import ActivityKit
import WidgetKit
import SwiftUI
import PikoKit
import PikoUI

struct PikoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PikoAttributes.self) { context in
            VStack {
                PikoFace(phase: context.state.phase, skin: context.attributes.skin)
                Text("\(context.state.words) words")
                Button(intent: StopSessionIntent()) {
                    Label("Stop", systemImage: "stop.fill")
                }
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    PikoFace(phase: context.state.phase, skin: context.attributes.skin)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: StopSessionIntent()) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            } compactLeading: {
                PikoFace(phase: context.state.phase, skin: context.attributes.skin)
            } compactTrailing: {
                PikoFace(phase: context.state.phase, skin: context.attributes.skin)
            } minimal: {
                PikoFace(phase: context.state.phase, skin: context.attributes.skin)
            }
        }
    }
}
