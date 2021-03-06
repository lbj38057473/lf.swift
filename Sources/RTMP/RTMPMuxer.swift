import Foundation
import AVFoundation

// MARK: - RTMPMuxerDelegate
protocol RTMPMuxerDelegate: class {
    func sampleOutput(muxer:RTMPMuxer, audio buffer:NSData, timestamp:Double)
    func sampleOutput(muxer:RTMPMuxer, video buffer:NSData, timestamp:Double)
}

// MARK: - RTMPMuxer
final class RTMPMuxer {
    weak var delegate:RTMPMuxerDelegate? = nil

    private var audioTimestamp:CMTime = kCMTimeZero
    private var videoTimestamp:CMTime = kCMTimeZero

    func dispose() {
        audioTimestamp = kCMTimeZero
        videoTimestamp = kCMTimeZero
    }
}

// MARK: AudioEncoderDelegate
extension RTMPMuxer: AudioEncoderDelegate {
    func didSetFormatDescription(audio formatDescription: CMFormatDescriptionRef?) {
        guard let formatDescription:CMFormatDescriptionRef = formatDescription else {
            return
        }
        let buffer:NSMutableData = NSMutableData()
        let config:[UInt8] = AudioSpecificConfig(formatDescription: formatDescription).bytes
        var data:[UInt8] = [0x00, FLVAACPacketType.Seq.rawValue]
        data[0] =  FLVAudioCodec.AAC.rawValue << 4 | FLVSoundRate.KHz44.rawValue << 2 | FLVSoundSize.Snd16bit.rawValue << 1 | FLVSoundType.Stereo.rawValue
        buffer.appendBytes(&data, length: data.count)
        buffer.appendBytes(config, length: config.count)
        delegate?.sampleOutput(self, audio: buffer, timestamp: 0)
    }

    func sampleOutput(audio sampleBuffer: CMSampleBuffer) {
        var blockBuffer:CMBlockBufferRef?
        var audioBufferList:AudioBufferList = AudioBufferList()
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, nil, &audioBufferList, sizeof(AudioBufferList.self), nil, nil, 0, &blockBuffer
        )
        let buffer:NSMutableData = NSMutableData()
        var data:[UInt8] = [0x00, FLVAACPacketType.Raw.rawValue]
        data[0] = FLVAudioCodec.AAC.rawValue << 4 | FLVSoundRate.KHz44.rawValue << 2 | FLVSoundSize.Snd16bit.rawValue << 1 | FLVSoundType.Stereo.rawValue
        buffer.appendBytes(&data, length: data.count)
        buffer.appendBytes(audioBufferList.mBuffers.mData, length: Int(audioBufferList.mBuffers.mDataByteSize))
        let presentationTimeStamp:CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let delta:Double = (audioTimestamp == kCMTimeZero ? 0 : CMTimeGetSeconds(presentationTimeStamp) - CMTimeGetSeconds(audioTimestamp)) * 1000
        delegate?.sampleOutput(self, audio: buffer, timestamp: delta)
        audioTimestamp = presentationTimeStamp
    }
}

// MARK: VideoEncoderDelegate
extension RTMPMuxer: VideoEncoderDelegate {

    func didSetFormatDescription(video formatDescription: CMFormatDescriptionRef?) {
        guard let
            formatDescription:CMFormatDescriptionRef = formatDescription,
            avcC:NSData = AVCConfigurationRecord.getData(formatDescription) else {
            return
        }
        let buffer:NSMutableData = NSMutableData()
        var data:[UInt8] = [UInt8](count: 5, repeatedValue: 0x00)
        data[0] = FLVFrameType.Key.rawValue << 4 | FLVVideoCodec.AVC.rawValue
        data[1] = FLVAVCPacketType.Seq.rawValue
        buffer.appendBytes(&data, length: data.count)
        buffer.appendData(avcC)
        delegate?.sampleOutput(self, video: buffer, timestamp: 0)
    }

    func sampleOutput(video sampleBuffer: CMSampleBuffer) {
        guard let block:CMBlockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }
        var keyframe:Bool = false
        if let attachments:CFArrayRef = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false) {
            if let attachment:Dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), CFDictionaryRef.self) as Dictionary? {
                let dependsOnOthers:Bool = attachment["DependsOnOthers"] as! Bool
                keyframe = dependsOnOthers == false
            }
        }
        var totalLength:Int = 0
        var dataPointer:UnsafeMutablePointer<Int8> = nil
        guard IsNoErr(CMBlockBufferGetDataPointer(block, 0, nil, &totalLength, &dataPointer)) else {
            return
        }

        var cto:Int32 = 0
        let pts:CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var dts:CMTime = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)

        if (dts == kCMTimeInvalid) {
            dts = pts
        } else {
            cto = Int32((CMTimeGetSeconds(pts) - CMTimeGetSeconds(dts)) * 1000)
        }
        let delta:Double = (videoTimestamp == kCMTimeZero ? 0 : CMTimeGetSeconds(dts) - CMTimeGetSeconds(videoTimestamp)) * 1000

        let buffer:NSMutableData = NSMutableData()
        var data:[UInt8] = [UInt8](count: 5, repeatedValue: 0x00)
        data[0] = ((keyframe ? FLVFrameType.Key.rawValue : FLVFrameType.Inter.rawValue) << 4) | FLVVideoCodec.AVC.rawValue
        data[1] = FLVAVCPacketType.Nal.rawValue
        data[2..<5] = cto.bigEndian.bytes[1..<4]
        buffer.appendBytes(&data, length: data.count)
        buffer.appendBytes(dataPointer, length: totalLength)
        delegate?.sampleOutput(self, video: buffer, timestamp: delta)
        videoTimestamp = dts
    }
}
