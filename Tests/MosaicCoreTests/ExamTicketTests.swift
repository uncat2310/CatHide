import CoreGraphics
@testable import MosaicCore
import XCTest

/// An exam admission ticket: tight form rows and running text with 签字笔.
final class ExamTicketTests: XCTestCase {
    func testNoFalseNameAndNoOverlappingBoxes() throws {
        let image = makeTextImage([
            "姓    名：张小明",
            "身份证号：430102199001011234",
            "准考证号：20261122038028",
            "考点名称：长沙市望城区长郡月亮岛学校",
            "1.考生打印《准考证》后，请认真核对相关信息，确认考试时间和地点，如发现错误请及时报告（0731-",
            "88123456）。务必妥善保存《准考证》，招聘工作后续环节还需查验。",
            "4.本次笔试考室设置安检，并全程视频监控；请自备2B铅笔、橡皮擦、黑色墨水签字笔参加笔试，严禁将电子、通",
            "信、计算、存储等设备和考试相关资料带进考场。",
        ], width: 2000, lineHeight: 44)
        let found = try SensitiveDetector.detect(in: image)
        XCTAssertFalse(found.contains { $0.text.contains("笔") }, "\(found)")
        XCTAssertEqual(Set(found.map(\.kind)), [.name, .id, .number, .phone])
        for a in found {
            for b in found where a.id < b.id {
                XCTAssertFalse(a.rect.intersects(b.rect), "\(a.text) overlaps \(b.text)")
            }
        }
        if let out = ProcessInfo.processInfo.environment["CATHIDE_DUMP"] {
            let strokes = found.map { $0.stroke(imageWidth: image.width, imageHeight: image.height, style: .blur, granularity: .medium, group: 1) }
            let rendered = try XCTUnwrap(MosaicRenderer.renderFinalImage(original: image, strokes: strokes, granularity: .medium, style: .blur))
            try XCTUnwrap(MosaicRenderer.encodeImage(rendered, format: .png)).write(to: URL(fileURLWithPath: out))
        }
    }
}
