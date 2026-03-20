import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers

enum AudioExportFormat: String, CaseIterable {
    case wav, mp3, m4a

    var utType: UTType {
        switch self {
        case .wav: return .wav
        case .mp3: return .mp3
        case .m4a: return .mpeg4Audio
        }
    }

    var fileExtension: String { rawValue }

    static func from(url: URL) -> AudioExportFormat {
        switch url.pathExtension.lowercased() {
        case "mp3": return .mp3
        case "m4a": return .m4a
        default: return .wav
        }
    }
}

enum AudioExporter {

    /// Export a CAF source file to the given destination in the specified format.
    static func export(sourceURL: URL, to destURL: URL, format: AudioExportFormat) throws {
        switch format {
        case .wav:
            try exportWAV(source: sourceURL, dest: destURL)
        case .mp3:
            try exportCompressed(source: sourceURL, dest: destURL, formatID: kAudioFormatMPEGLayer3, fileType: kAudioFileMP3Type)
        case .m4a:
            try exportM4A(source: sourceURL, dest: destURL)
        }
    }

    // MARK: - WAV export via ExtAudioFile

    private static func exportWAV(source: URL, dest: URL) throws {
        var sourceFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(source as CFURL, &sourceFile)
        guard status == noErr, let src = sourceFile else {
            throw AudioExportError.openFailed(status)
        }
        defer { ExtAudioFileDispose(src) }

        // Read source format
        var srcFormat = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(src, kExtAudioFileProperty_FileDataFormat, &propSize, &srcFormat)

        // WAV output format: 16-bit PCM
        var dstFormat = AudioStreamBasicDescription(
            mSampleRate: srcFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var destFile: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(
            dest as CFURL,
            kAudioFileWAVEType,
            &dstFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &destFile
        )
        guard status == noErr, let dst = destFile else {
            throw AudioExportError.createFailed(status)
        }
        defer { ExtAudioFileDispose(dst) }

        // Set client format to read as Float32 (source format)
        var clientFormat = srcFormat
        ExtAudioFileSetProperty(src, kExtAudioFileProperty_ClientDataFormat,
                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        ExtAudioFileSetProperty(dst, kExtAudioFileProperty_ClientDataFormat,
                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)

        // Copy in chunks
        let bufferFrames: UInt32 = 4096
        let bufferSize = Int(bufferFrames) * MemoryLayout<Float>.size
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(bufferFrames))
        defer { buffer.deallocate() }

        while true {
            let audioBuffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bufferSize),
                mData: buffer
            )
            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
            var frameCount = bufferFrames

            status = ExtAudioFileRead(src, &frameCount, &bufferList)
            guard status == noErr else { throw AudioExportError.readFailed(status) }
            guard frameCount > 0 else { break }

            status = ExtAudioFileWrite(dst, frameCount, &bufferList)
            guard status == noErr else { throw AudioExportError.writeFailed(status) }
        }
    }

    // MARK: - M4A export via AVAssetWriter

    private static func exportM4A(source: URL, dest: URL) throws {
        try exportCompressed(source: source, dest: dest, formatID: kAudioFormatMPEG4AAC, fileType: kAudioFileM4AType)
    }

    // MARK: - Compressed export (MP3/M4A) via ExtAudioFile

    private static func exportCompressed(source: URL, dest: URL, formatID: AudioFormatID, fileType: AudioFileTypeID) throws {
        var sourceFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(source as CFURL, &sourceFile)
        guard status == noErr, let src = sourceFile else {
            throw AudioExportError.openFailed(status)
        }
        defer { ExtAudioFileDispose(src) }

        var srcFormat = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(src, kExtAudioFileProperty_FileDataFormat, &propSize, &srcFormat)

        var dstFormat = AudioStreamBasicDescription(
            mSampleRate: srcFormat.mSampleRate,
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // Let the system fill in the rest
        var dstFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFormatGetProperty(
            kAudioFormatProperty_FormatInfo,
            0, nil,
            &dstFormatSize, &dstFormat
        )

        var destFile: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(
            dest as CFURL,
            fileType,
            &dstFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &destFile
        )
        guard status == noErr, let dst = destFile else {
            throw AudioExportError.createFailed(status)
        }
        defer { ExtAudioFileDispose(dst) }

        // Set client data format to Float32
        var clientFormat = srcFormat
        ExtAudioFileSetProperty(src, kExtAudioFileProperty_ClientDataFormat,
                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        ExtAudioFileSetProperty(dst, kExtAudioFileProperty_ClientDataFormat,
                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)

        let bufferFrames: UInt32 = 4096
        let bufferSize = Int(bufferFrames) * MemoryLayout<Float>.size
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(bufferFrames))
        defer { buffer.deallocate() }

        while true {
            let audioBuffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bufferSize),
                mData: buffer
            )
            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
            var frameCount = bufferFrames

            status = ExtAudioFileRead(src, &frameCount, &bufferList)
            guard status == noErr else { throw AudioExportError.readFailed(status) }
            guard frameCount > 0 else { break }

            status = ExtAudioFileWrite(dst, frameCount, &bufferList)
            guard status == noErr else { throw AudioExportError.writeFailed(status) }
        }
    }
}

enum AudioExportError: LocalizedError {
    case openFailed(OSStatus)
    case createFailed(OSStatus)
    case readFailed(OSStatus)
    case writeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .openFailed(let s): return "Failed to open source audio (OSStatus \(s))"
        case .createFailed(let s): return "Failed to create output file (OSStatus \(s))"
        case .readFailed(let s): return "Failed to read audio data (OSStatus \(s))"
        case .writeFailed(let s): return "Failed to write audio data (OSStatus \(s))"
        }
    }
}
