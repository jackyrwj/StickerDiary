import WidgetKit
import SwiftUI

@main
struct StickerWidgetBundle: WidgetBundle {
    var body: some Widget {
        StickerWidget()
        DiaryWidget()
    }
}
