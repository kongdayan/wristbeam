import Foundation
import CryptoKit
import XCTest
@testable import GarminBar

final class ConnectIQInstallerTests: XCTestCase {
    private let package = Data((0..<1300).map { UInt8(truncatingIfNeeded: $0) })
    private func sender() throws -> GFDIConnectIQInstaller {
        try GFDIConnectIQInstaller(data: package, expectedSHA256: SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined(), sourceMessageID: 0x12345678)
    }
    private func uploadResponse(offset: UInt32 = 0, crc: UInt16 = 0, maximum: UInt32 = 2000) -> Data {
        var w = GFDIWriter(); w.u8(0); w.u32(offset); w.u32(maximum); w.u16(crc); return Data(w.bytes)
    }
    private func blockACK(_ offset: UInt32) -> Data {
        var w = GFDIWriter(); w.u8(0); w.u32(offset); return Data(w.bytes)
    }
    func testOfficialCreateAndUncompressedUploadWireLayouts() throws {
        let upload = try sender()
        XCTAssertEqual(upload.createRequest, Data([0x14,5,0,0,0xff,0x11,0,0,0,0,0xff,0xff,0,0,0x78,0x56,0x34,0x12,0,0,0,0]))
        XCTAssertEqual(upload.uploadRequest(index: 0x1234), Data([0x34,0x12,0x14,5,0,0,0,0,0,0,0,0]))
        XCTAssertEqual(try GFDIConnectIQInstaller.createdIndex(Data([1,0x34,0x12])), 0x1234)
        XCTAssertThrowsError(try GFDIConnectIQInstaller.createdIndex(Data([2,0,0])))
        XCTAssertThrowsError(try GFDIConnectIQInstaller.createdIndex(Data([0,1])))
    }
    func testBlocksReassembleUnchangedPackageWithCumulativeCRCAndExactRetries() throws {
        var upload = try sender(); try upload.acceptUpload(uploadResponse())
        var received = Data()
        while !upload.complete {
            let start = upload.offset
            let block = try upload.nextBlock(maximumPacketSize: 512)
            var r = GFDIReader(block)
            XCTAssertEqual(try r.u8(), 0)
            let crc = try r.u16(); XCTAssertEqual(try r.u32(), UInt32(start))
            let chunk = try r.data(r.remaining)
            XCTAssertLessThanOrEqual(chunk.count, 494)
            XCTAssertEqual(crc, GFDICRC.calculate(package.prefix(start + chunk.count)))
            XCTAssertFalse(try upload.acceptBlock(Data([1])))
            XCTAssertEqual(upload.offset, start)
            XCTAssertEqual(try upload.nextBlock(maximumPacketSize: 512), block)
            XCTAssertThrowsError(try upload.acceptBlock(blockACK(UInt32(start + chunk.count + 1))))
            XCTAssertEqual(upload.offset, start)
            XCTAssertTrue(try upload.acceptBlock(blockACK(UInt32(start + chunk.count))))
            received.append(chunk)
        }
        XCTAssertEqual(received, package)
        XCTAssertEqual(upload.progress, 1)
    }
    func testResumeRequiresPrefixCRCAndRestartSurvivesRetry() throws {
        var resumed = try sender()
        try resumed.acceptUpload(uploadResponse(offset: 500, crc: GFDICRC.calculate(package.prefix(500))))
        XCTAssertEqual(resumed.offset, 500)
        XCTAssertEqual(try resumed.nextBlock(maximumPacketSize: 512).first, 0)
        var restarted = try sender()
        try restarted.acceptUpload(uploadResponse(offset: 500, crc: 0xffff))
        XCTAssertEqual(restarted.offset, 0)
        let block = try restarted.nextBlock(maximumPacketSize: 512)
        XCTAssertEqual(block.first, 1)
        XCTAssertFalse(try restarted.acceptBlock(Data([1])))
        XCTAssertEqual(try restarted.nextBlock(maximumPacketSize: 512), block)
        XCTAssertTrue(try restarted.acceptBlock(blockACK(UInt32(block.count - 7))))
        XCTAssertEqual(try restarted.nextBlock(maximumPacketSize: 512).first, 0)
        var completeRemote = try sender()
        try completeRemote.acceptUpload(uploadResponse(offset: 1300))
        XCTAssertEqual(completeRemote.offset, 0)
        XCTAssertEqual(try completeRemote.nextBlock(maximumPacketSize: 512).first, 1)
    }
    func testInvalidPackageCapacityAndRepliesFailClosed() throws {
        XCTAssertThrowsError(try GFDIConnectIQInstaller(data: package, expectedSHA256: String(repeating: "0", count: 64), sourceMessageID: 1))
        let digest = SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try GFDIConnectIQInstaller(data: package, expectedSHA256: digest, sourceMessageID: UInt64(1) << 54))
        var upload = try sender()
        XCTAssertThrowsError(try upload.acceptUpload(uploadResponse(maximum: 100)))
        XCTAssertThrowsError(try upload.acceptUpload(Data([0,0])))
        try upload.acceptUpload(uploadResponse())
        _ = try upload.nextBlock(maximumPacketSize: 512)
        XCTAssertThrowsError(try upload.acceptBlock(Data([3])))
        XCTAssertThrowsError(try upload.acceptBlock(Data([4])))
        XCTAssertEqual(upload.offset, 0)
    }
}
