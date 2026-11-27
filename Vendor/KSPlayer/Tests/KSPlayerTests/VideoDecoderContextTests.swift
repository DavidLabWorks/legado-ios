import Libavcodec
import XCTest
@testable import KSPlayer

final class VideoDecoderContextTests: XCTestCase {
    func testPixelFormatNegotiationReusesTheDeviceOwnedByTheDecoder() throws {
        var parameters = AVCodecParameters()
        parameters.codec_type = AVMEDIA_TYPE_VIDEO
        parameters.codec_id = AV_CODEC_ID_H264
        let options = KSOptions()
        options.hardwareDecode = true
        var context: UnsafeMutablePointer<AVCodecContext>? = try parameters.createContext(options: options)
        defer { avcodec_free_context(&context) }
        let decoder = try XCTUnwrap(context)
        let device = try XCTUnwrap(decoder.pointee.hw_device_ctx)
        let selectFormat = try XCTUnwrap(decoder.pointee.get_format)
        let formats = [AV_PIX_FMT_VIDEOTOOLBOX, AV_PIX_FMT_YUV420P, AV_PIX_FMT_NONE]
        for _ in 0..<2 {
            XCTAssertEqual(selectFormat(decoder, formats), AV_PIX_FMT_VIDEOTOOLBOX)
            XCTAssertEqual(decoder.pointee.hw_device_ctx, device)
        }
        XCTAssertEqual(selectFormat(decoder, [AV_PIX_FMT_YUV420P, AV_PIX_FMT_NONE]), AV_PIX_FMT_YUV420P)
    }
}
