import Foundation
import whisper_cpp

public class Whisper {
    private let whisperContext: OpaquePointer

    public var delegate: WhisperDelegate?
    public var params: WhisperParams
    public private(set) var inProgress = false

    internal var frameCount: Int? // Manually track total audio frames for progress calculation (value not in `whisper_state` yet)

    public init(fromFileURL fileURL: URL, withParams params: WhisperParams = .default) {
        self.whisperContext = fileURL.relativePath.withCString { whisper_init_from_file($0) }
        self.params = params

        prepareCallbacks()
    }

    public init(fromData data: Data, withParams params: WhisperParams = .default) {
        var copy = data // Need to copy memory so we can gaurentee exclusive ownership over pointer

        self.whisperContext = copy.withUnsafeMutableBytes { whisper_init_from_buffer($0.baseAddress!, data.count) }
        self.params = params

        prepareCallbacks()
    }

    deinit {
        whisper_free(whisperContext)
    }

    private func prepareCallbacks() {
        /*
         C-style callbacks can't capture any references in swift, so we'll convert `self`
         to a pointer which whisper passes back as `new_segment_callback_user_data`.

         We can unwrap that and obtain a copy of self inside the callback.
         */
        params.new_segment_callback_user_data = Unmanaged.passRetained(self).toOpaque()

        params.new_segment_callback = { (ctx: OpaquePointer?, _: OpaquePointer?, newSegmentCount: Int32, userData: UnsafeMutableRawPointer?) in
            guard let ctx, let userData else { return }
            let whisper = Unmanaged<Whisper>.fromOpaque(userData).takeUnretainedValue()
            guard let delegate = whisper.delegate else { return }

            let segmentCount = whisper_full_n_segments(ctx)
            var newSegments: [Segment] = []
            newSegments.reserveCapacity(Int(newSegmentCount))

            let startIndex = segmentCount - newSegmentCount

            for i in startIndex..<segmentCount {
                guard let text = whisper_full_get_segment_text(ctx, i) else { continue }
                let startTime = whisper_full_get_segment_t0(ctx, i)
                let endTime = whisper_full_get_segment_t1(ctx, i)

                newSegments.append(.init(
                    startTime: Int(startTime) * 10, // Time is given in ms/10, so correct for that
                    endTime: Int(endTime) * 10,
                    text: String(Substring(cString: text))
                ))
            }

            if let frameCount = whisper.frameCount,
               let lastSegmentTime = newSegments.last?.endTime {

                let fileLength = Double(frameCount * 1000) / Double(WHISPER_SAMPLE_RATE)
                let progress = Double(lastSegmentTime) / Double(fileLength)

                DispatchQueue.main.async {
                    delegate.whisper(whisper, didUpdateProgress: progress)
                }
            }

            DispatchQueue.main.async {
                delegate.whisper(whisper, didProcessNewSegments: newSegments, atIndex: Int(startIndex))
            }
        }
    }

    public func transcribe(audioFrames: [Float], completionHandler: @escaping (Result<[Segment], Error>) -> Void) {
        guard !inProgress else {
            completionHandler(.failure(WhisperError.instanceBusy))
            return
        }
        guard audioFrames.count > 0 else {
            completionHandler(.failure(WhisperError.invalidFrames))
            return
        }

        inProgress = true
        frameCount = audioFrames.count

        DispatchQueue.global(qos: .userInitiated).async { [unowned self] in

            whisper_full(whisperContext, params.whisperParams, audioFrames, Int32(audioFrames.count))

            let segmentCount = whisper_full_n_segments(whisperContext)

            var segments: [Segment] = []
            segments.reserveCapacity(Int(segmentCount))

            for i in 0..<segmentCount {
                guard let text = whisper_full_get_segment_text(whisperContext, i) else { continue }
                let startTime = whisper_full_get_segment_t0(whisperContext, i)
                let endTime = whisper_full_get_segment_t1(whisperContext, i)

                segments.append(
                    .init(
                        startTime: Int(startTime) * 10, // Correct for ms/10
                        endTime: Int(endTime) * 10,
                        text: String(Substring(cString: text))
                    )
                )
            }

            DispatchQueue.main.async {
                self.frameCount = nil
                self.inProgress = true

                self.delegate?.whisper(self, didCompleteWithSegments: segments)
                completionHandler(.success(segments))
            }
        }
    }

    @available(iOS 13, macOS 10.15, *)
    public func transcribe(audioFrames: [Float]) async throws -> [Segment] {
        return try await withCheckedThrowingContinuation { cont in
            self.transcribe(audioFrames: audioFrames) { result in
                switch result {
                case .success(let segments):
                    cont.resume(returning: segments)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
